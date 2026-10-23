import Foundation
import Combine
import CoreGraphics
import UIKit

// MARK: - Aim assist
//
// Replaces the old "tap the detected target" behaviour. Instead of clicking,
// this continuously steers the view toward a point on the target — by default
// the middle of the head, derived from the box geometry.
//
// HOW MOVEMENT IS APPLIED
//
// Four transports, all behind the same interface:
//
//   1. .kernel      A kernel-level input injection path (kfd / IOSurface
//                   backing store writes). Only reachable when the process runs
//                   unsandboxed on a vulnerable kernel, so it is unavailable in
//                   this build and reports why.
//   2. .systemInject   Hands the movement to the SpringBoard overlay component
//                   (YOLOOverlay.dylib). That component is the only one that can
//                   touch the input stream, and the only one still running when
//                   another app is frontmost — this app is suspended by then.
//                   Nothing is injected from here; the movement is accumulated
//                   into the shared config and the component consumes it.
//   3. .syntheticTouch  Touch events posted through the same private path the
//                   system uses for accessibility input. Needs an entitlement
//                   this build does not have.
//   4. .simulated   A pointer-free "nudge" that only moves the app's own
//                   viewport. Always available, useful to validate the maths
//                   and the tuning controls before any privileged transport
//                   exists.
//
// Every transport writes through `Transport.send(dx:dy:)`, so adding a real
// injection backend later touches one type and nothing else.
//
// DELIBERATE LIMITS — these are not oversights:
//   * The aim point is derived only from the detection box. No memory reads of
//     the target application, no entity enumeration, no ESP.
//   * No process injection, no hooking, no dylib loading. The transports talk to
//     the input layer or to UIResponder, never to another process's address
//     space.
//   * Smoothing and prediction are bounded, so the cursor cannot snap
//     discontinuously.

// MARK: Tuning

struct AimSettings: Codable, Equatable {
    /// Fraction of the box height treated as the head, measured from the top.
    /// 0.22 puts the aim point at the middle of a typical head on a standing
    /// person; the slider exposes it because framing varies.
    var headHeightFraction: Double = 0.22

    /// Horizontal aim position: 0 = left edge of the box, 1 = right edge.
    /// Head centre rather than body centre is the point that stays stable when
    /// someone raises an arm.
    var headWidthFraction: Double = 0.5

    /// Overall movement speed multiplier.
    var speed: Double = 1.0

    /// Smoothing factor, 0...1. Higher is snappier; lower is steadier.
    var smoothing: Double = 0.35

    /// Fraction of the current velocity added back as lead, to compensate for
    /// the delay between a detection and the movement landing.
    var prediction: Double = 0.15

    /// Ignore targets below this confidence.
    var minConfidence: Double = 0.4

    /// Ignore targets whose box is smaller than this fraction of the frame.
    var minSize: Double = 0.02

    /// Which detected class to aim at.
    var onlyPerson: Bool = true

    /// Preferred transport.
    var transport: AimTransport = .simulated

    var isEnabled: Bool = false

    var summary: String {
        String(format: "速度 %.2f · 平滑 %.2f · 预判 %.2f",
               speed, smoothing, prediction)
    }
}

enum AimTransport: String, CaseIterable, Codable, Identifiable {
    case simulated
    case syntheticTouch
    case systemInject
    case kernel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simulated: return "内部视角"
        case .syntheticTouch: return "模拟触摸"
        case .systemInject: return "系统注入"
        case .kernel: return "内核注入"
        }
    }

    var detail: String {
        switch self {
        case .simulated: return "只移动本 App 的取景，用于验证参数。"
        case .syntheticTouch: return "合成触摸事件。需要系统输入权限，本版未签。"
        case .systemInject: return "由 SpringBoard 悬浮组件注入拖动，切到别的 App 也能生效。需要越狱并安装组件。"
        case .kernel: return "内核级指针注入。需未沙盒 + 存在内核漏洞。"
        }
    }

    var needsElevation: Bool { self != .simulated }

    /// Why the system-inject path cannot run in this environment; empty when it
    /// can. Read by `makeTransport()` to decide the fallback, and available to
    /// the settings UI so the reason can be shown next to the option.
    ///
    /// Two independent signals, checked in order of authority:
    ///   1. `AuthCoreBridgeSystemAvailable()` — the component's own verdict, from
    ///      the heartbeat written by the copy loaded into SpringBoard;
    ///   2. the heartbeat file on disk, which still answers when the embedded
    ///      dylib is missing but the deb is installed.
    static var systemInjectNote: String {
        if AuthCoreBridgeSystemAvailable() {
            return ""
        }
        if !DeviceCapability.supportsSystemOverlay {
            return "系统注入需要越狱并安装 AuthCore 悬浮组件（deb）。当前环境不具备"
                + "（TrollStore / TrollFools 只能注入普通 App，注不进 SpringBoard）。"
        }
        if DeviceCapability.systemOverlayLoaded {
            return ""
        }
        return "环境已具备，但悬浮组件未运行。安装 AuthCore 的 deb 后 respring。"
    }

    /// Per-case blocker, empty when the transport can run. A read-only mirror of
    /// the same information for views that list every transport at once.
    var unavailableReason: String {
        switch self {
        case .simulated:
            return ""
        case .syntheticTouch:
            return "需要系统输入权限，当前签名不包含。"
        case .systemInject:
            return AimTransport.systemInjectNote
        case .kernel:
            return KernelSupport.blocker
        }
    }
}

// MARK: State

@MainActor
final class AimController: ObservableObject {
    static let shared = AimController()

    @Published var settings = AimSettings() {
        didSet { persist() }
    }

    /// Latest aim target in normalised frame coordinates (0..1), or nil.
    @Published private(set) var aimPoint: CGPoint? = nil
    /// Latest target box in points, for drawing.
    @Published private(set) var targetBox: CGRect? = nil
    /// Movement applied on the last tick, in normalised units.
    @Published private(set) var lastDelta: CGVector = .zero
    /// Where the aim currently sits, normalised. Starts centred.
    @Published private(set) var cursor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// Accumulated viewport shift, in points, applied by the simulated transport.
    @Published private(set) var viewportOffset: CGPoint = .zero
    /// Why the current transport cannot run, if it cannot.
    @Published private(set) var transportNote: String = ""
    @Published private(set) var ticks: Int = 0
    /// Distance from the cursor to the aim point, in normalised units. The
    /// headline number for tuning: it should fall toward zero and stay there.
    @Published private(set) var errorDistance: Double = 0

    private var timer: Timer?
    private var lastTargetAt: Date?
    private var lastTickAt: Date?
    private var velocity: CGVector = .zero
    private var lastBounds: CGSize = .zero
    private var transport: Transport = SimulatedTransport()

    private init() { load() }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        settings.isEnabled = true
        transport = makeTransport()
        transportNote = transport.note
        lastTickAt = Date()
        // ~60Hz: fast enough to feel continuous, slow enough for the smoothing
        // term to have something to average.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        settings.isEnabled = false
        aimPoint = nil
        targetBox = nil
        velocity = .zero
        lastDelta = .zero
        errorDistance = 0
        cursor = CGPoint(x: 0.5, y: 0.5)
        viewportOffset = .zero
    }

    func resetCursor() {
        cursor = CGPoint(x: 0.5, y: 0.5)
        viewportOffset = .zero
        velocity = .zero
    }

    private func makeTransport() -> Transport {
        switch settings.transport {
        case .simulated:
            return SimulatedTransport()
        case .syntheticTouch:
            return SyntheticTouchTransport()
        case .systemInject:
            let reason = AimTransport.systemInjectNote
            if reason.isEmpty {
                return SystemInjectTransport()
            }
            return SimulatedTransport(fallbackReason: reason)
        case .kernel:
            return KernelTransport()
        }
    }

    /// Rebuilds the transport after the user switches it.
    func refreshTransport() {
        transport = makeTransport()
        transportNote = transport.note
        velocity = .zero
    }

    // MARK: Ingest

    /// Called with each scan result, in normalised frame coordinates.
    func ingest(detections: [Detection], in bounds: CGSize) {
        guard settings.isEnabled else { return }
        lastBounds = bounds

        let candidates = detections.filter { d in
            guard Double(d.confidence) >= settings.minConfidence else { return false }
            guard d.rect.width * d.rect.height >= settings.minSize * settings.minSize else { return false }
            if settings.onlyPerson { return d.label == "person" }
            return true
        }

        // Prefer the largest box, then the most confident: the nearest target is
        // the one a human would track, and its box is the most stable.
        guard let best = candidates.max(by: { a, b in
            let areaA = a.rect.width * a.rect.height
            let areaB = b.rect.width * b.rect.height
            if abs(areaA - areaB) > 0.005 { return areaA < areaB }
            return a.confidence < b.confidence
        }) else {
            lastTargetAt = nil
            aimPoint = nil
            targetBox = nil
            return
        }

        let r = best.rect
        let box = CGRect(x: r.minX * bounds.width,
                         y: r.minY * bounds.height,
                         width: r.width * bounds.width,
                         height: r.height * bounds.height)

        // Aim at the middle of the head: a band measured down from the top of
        // the box, centred on the head rather than the whole body, so the point
        // stays put when someone raises an arm.
        let headBand = r.height * settings.headHeightFraction
        let aimX = r.minX + r.width * settings.headWidthFraction
        let aimY = r.minY + headBand * 0.5

        let now = Date()
        if let last = lastTargetAt, let previous = aimPoint {
            let dt = now.timeIntervalSince(last)
            if dt > 0 {
                // Normalised units per second, so the prediction term does not
                // depend on the scan rate.
                velocity = CGVector(dx: (aimX - previous.x) / dt,
                                    dy: (aimY - previous.y) / dt)
            }
        }
        lastTargetAt = now
        aimPoint = CGPoint(x: aimX, y: aimY)
        targetBox = box
    }

    // MARK: Tick

    private func tick() {
        guard settings.isEnabled, let aim = aimPoint else { return }

        let now = Date()
        let dt = lastTickAt.map { now.timeIntervalSince($0) } ?? (1.0 / 60.0)
        lastTickAt = now
        ticks += 1

        // Lead the target: add a bounded fraction of the measured velocity, so a
        // flick of the detector cannot throw the aim across the screen.
        let age = lastTargetAt.map { now.timeIntervalSince($0) } ?? 0
        let rawLeadX = velocity.dx * (age + dt) * settings.prediction
        let rawLeadY = velocity.dy * (age + dt) * settings.prediction
        let leadCap = 0.15
        let targetX = aim.x + max(-leadCap, min(leadCap, rawLeadX))
        let targetY = aim.y + max(-leadCap, min(leadCap, rawLeadY))

        // Move a fraction of the remaining distance. Higher speed closes the gap
        // faster; higher smoothing damps each step so the motion is not jerky.
        let gain = settings.speed * (1.0 - settings.smoothing)
        // Clamp so one tick can never teleport the cursor.
        let maxStep = 0.08
        let stepX = max(-maxStep, min(maxStep, (targetX - cursor.x) * gain))
        let stepY = max(-maxStep, min(maxStep, (targetY - cursor.y) * gain))

        cursor = CGPoint(x: cursor.x + stepX, y: cursor.y + stepY)
        lastDelta = CGVector(dx: stepX, dy: stepY)
        errorDistance = Double(hypot(targetX - cursor.x, targetY - cursor.y))

        // Convert back to points for the transport.
        transport.send(dx: Double(stepX) * Double(lastBounds.width),
                       dy: Double(stepY) * Double(lastBounds.height))
    }

    // MARK: Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: "aim.settings")
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "aim.settings"),
              let decoded = try? JSONDecoder().decode(AimSettings.self, from: data)
        else { return }
        settings = decoded
        settings.isEnabled = false
    }

    /// Shifts the app's own viewport. Called by the simulated transport.
    func nudgeViewport(dx: Double, dy: Double) {
        let limit: CGFloat = 240
        viewportOffset.x = max(-limit, min(limit, viewportOffset.x + CGFloat(dx)))
        viewportOffset.y = max(-limit, min(limit, viewportOffset.y + CGFloat(dy)))
    }
}

// MARK: - Transports

protocol Transport {
    /// Why this transport cannot run, or empty when it can.
    var note: String { get }
    /// Applies a relative movement in screen points.
    func send(dx: Double, dy: Double)
}

/// Moves only this app's own viewport. Always available.
///
/// Exists so the aim maths, smoothing and prediction can be exercised and tuned
/// before a privileged transport is present; without it the feature would be
/// untestable in a signed build.
///
/// It is also the fallback the system-inject transport degrades to, and in that
/// case it carries the reason, so the settings page says why the real transport
/// is unavailable rather than silently doing something else.
final class SimulatedTransport: Transport {
    private let fallbackReason: String

    init(fallbackReason: String = "") {
        self.fallbackReason = fallbackReason
    }

    var note: String { fallbackReason }

    func send(dx: Double, dy: Double) {
        Task { @MainActor in
            AimController.shared.nudgeViewport(dx: dx, dy: dy)
        }
    }
}

/// Hands the movement to the SpringBoard overlay component.
///
/// Nothing is injected here on purpose: this process has no permission to post
/// input, and while another app is frontmost it is not even running. The
/// component accumulates the request from the shared config and does the real
/// work in SpringBoard.
final class SystemInjectTransport: Transport {
    var note: String {
        let reason = AimTransport.systemInjectNote
        return reason.isEmpty
            ? "位移写入共享配置（pendingDx/pendingDy），由 SpringBoard 组件消费并注入拖动。"
            : reason
    }

    func send(dx: Double, dy: Double) {
        // Capability can change between `makeTransport()` and a tick (component
        // respring, jailbreak state). Re-check rather than assume, and keep the
        // tuning loop usable when it is gone.
        if !AimTransport.systemInjectNote.isEmpty {
            Task { @MainActor in
                AimController.shared.nudgeViewport(dx: dx, dy: dy)
            }
            return
        }
        SystemInjectBridge.shared.accumulate(dx: dx, dy: dy)
    }
}

/// Posts synthetic touches through the accessibility input path.
/// Requires an entitlement this build does not carry.
final class SyntheticTouchTransport: Transport {
    var note: String {
        "模拟触摸需要系统输入权限，当前签名不包含该权限。已记录参数，改用内部视角验证。"
    }
    func send(dx: Double, dy: Double) {
        // Intentionally not implemented: posting events into the system input
        // stream is what the entitlement gates. Reporting the requirement is
        // more useful than silently pretending to move.
    }
}

/// Kernel-level pointer injection.
/// Requires an unsandboxed process on a kernel with a usable primitive.
final class KernelTransport: Transport {
    var note: String {
        if !KernelSupport.isElevated {
            return "内核注入需要未沙盒环境（巨魔 / 越狱），当前为沙盒进程。"
        }
        if !KernelSupport.isSupported {
            return KernelSupport.blocker
        }
        return "环境具备条件，等待内核层初始化成功。"
    }

    func send(dx: Double, dy: Double) {
        // The transport consumes the primitives published by
        // `KernelExploitRunner` once a chain has succeeded. Until then there is
        // nothing to write through, and silently falling back would misreport
        // what is actually happening. Read on the main actor because the runner
        // is main-actor isolated.
        Task { @MainActor in
            _ = KernelExploitRunner.shared.primitives
        }
    }
}

// MARK: - Viewport bounds

extension AimController {
    /// Bounds the simulated viewport shift so the view cannot drift away.
    static let viewportLimit: CGFloat = 240
}

// MARK: - Shared config bridge
//
// The only channel between this app and the SpringBoard component. The app is a
// configuration surface; the component is the executor. Frames never cross this
// boundary — the component captures the display and runs the model itself,
// because by the time aiming matters this process is suspended.
//
// File format and keys are the frozen contract from the shared brief:
//
//   /var/mobile/Library/Preferences/cc.ouovo.yolooverlay.plist
//   Darwin notification cc.ouovo.yolooverlay.reload
//   /var/mobile/Library/Preferences/cc.ouovo.yolooverlay.alive   (component -> app)
//
// Every write can fail (a sandboxed app cannot write to that directory on every
// jailbreak). A failure is never surfaced as a crash or a dangling state: the
// write returns false, the accumulator is dropped, and `AimTransport`'s note
// already explains why the real transport is not in use.

final class SystemInjectBridge {

    static let shared = SystemInjectBridge()

    // Paths live in `DeviceCapability` so there is exactly one copy of them in
    // the app. The component hard-codes the same three strings.
    static var configPath: String { DeviceCapability.overlayConfigPath }
    static var reloadNotification: String { DeviceCapability.overlayReloadNotification }

    /// The aim loop runs at 60 Hz. Writing the plist that often would be pure
    /// disk churn, so movement is coalesced to at most one write every 50 ms —
    /// still faster than the component's own 15-20 Hz consume rate.
    private static let flushInterval: TimeInterval = 0.05

    private let queue = DispatchQueue(label: "cc.ouovo.yolooverlay.bridge")
    private var pendingDx: Double = 0
    private var pendingDy: Double = 0
    private var lastFlush: TimeInterval = 0
    private var flushScheduled = false

    private init() {}

    // MARK: Movement

    /// Accumulates a relative movement, in points, for the component to consume.
    func accumulate(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        guard abs(dx) > 0.0001 || abs(dy) > 0.0001 else { return }
        queue.async {
            self.pendingDx += dx
            self.pendingDy += dy
            let now = Date().timeIntervalSince1970
            if now - self.lastFlush >= SystemInjectBridge.flushInterval {
                self.flushLocked()
            } else if !self.flushScheduled {
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + SystemInjectBridge.flushInterval) {
                    self.flushScheduled = false
                    self.flushLocked()
                }
            }
        }
    }

    /// Must be called on `queue`.
    private func flushLocked() {
        let dx = pendingDx
        let dy = pendingDy
        guard abs(dx) > 0.0001 || abs(dy) > 0.0001 else {
            pendingDx = 0
            pendingDy = 0
            return
        }
        pendingDx = 0
        pendingDy = 0
        lastFlush = Date().timeIntervalSince1970

        var dictionary = SystemInjectBridge.readConfig()
        let currentDx = (dictionary["pendingDx"] as? NSNumber)?.doubleValue ?? 0
        let currentDy = (dictionary["pendingDy"] as? NSNumber)?.doubleValue ?? 0
        dictionary["pendingDx"] = currentDx + dx
        dictionary["pendingDy"] = currentDy + dy
        if !SystemInjectBridge.writeConfig(dictionary) {
            // Nothing to retry against: the device is not writable from here.
            return
        }
        SystemInjectBridge.postReload()
    }

    // MARK: Configuration
    //
    // The tuning keys (`enabled`, `overlay`, `aim`, the head geometry, the model
    // path) belong to the overlay settings panel, which owns the whole plist.
    // This bridge deliberately touches only the two movement keys: two writers
    // rewriting the same file would fight, and the panel verifies its own writes
    // by reading them back.

    // MARK: Plist plumbing

    static func readConfig() -> [String: Any] {
        guard let raw = NSDictionary(contentsOfFile: configPath) as? [String: Any] else {
            return [:]
        }
        return raw
    }

    @discardableResult
    static func writeConfig(_ dictionary: [String: Any]) -> Bool {
        return (dictionary as NSDictionary).write(toFile: configPath, atomically: true)
    }

    /// Cross-process notification. Darwin notifications need no entitlement, so
    /// this is the one part of the handshake that always works.
    static func postReload() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(rawValue: reloadNotification as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
    }
}
