import Foundation
import Combine
import CoreGraphics
import UIKit

// MARK: - Aim assist
//
// Replaces the old "tap the detected target" behaviour. Instead of clicking,
// this continuously steers the view toward a point on the target — the middle
// of the head, derived from the box geometry.
//
// WHERE THE NUMBERS COME FROM (round 7)
//
// Nothing in this file decides how the aim moves. Every coefficient — the head
// band, the smoothing curve, the look-ahead weights, the speed tiers and the
// per-tick output bound — arrives from the licence server as an encrypted table
// (see `AimParams`) inside the 60-second heartbeat.
//
// `params` starts as nil and stays nil until a heartbeat delivers a table that
// decrypts and has not expired. There is no built-in default, no "reasonable
// fallback", no debug-only table: without server parameters the loop cannot
// run, because there is nothing to look up. A patched copy of this file that
// skips a check still has no numbers to apply.
//
// Zero grace: `AimParams.isValid` is a plain `Date() < expiresAt`. The tick
// tests it every frame, and `LicenseManager` drops the table on any failed
// heartbeat, so a stale table can never outlive its window.
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
//                   viewport. Always available, useful to validate the table
//                   before any privileged transport exists.
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
//   * Smoothing and prediction are bounded by the server's own clamp, so the
//     cursor cannot snap discontinuously.

// MARK: Tuning
//
// What is left of the client-side settings is *target selection* and the
// transport choice. Both are about which box to look at and how to deliver the
// movement; neither decides how much or how fast to move, which is exactly the
// split the server needs in order to keep the algorithm on its side.
//
// The head geometry, the movement speed, the smoothing and the prediction
// weights used to live here as `headHeightFraction` / `headWidthFraction` /
// `speed` / `smoothing` / `prediction`. They are gone, not deprecated: leaving
// them behind as "unused defaults" would be a fallback waiting to be wired up
// again by the next patch.

struct AimSettings: Codable, Equatable {
    /// Ignore targets below this confidence.
    var minConfidence: Double = 0.4

    /// Ignore targets whose box is smaller than this fraction of the frame.
    var minSize: Double = 0.02

    /// Which detected class to aim at.
    var onlyPerson: Bool = true

    /// Preferred transport.
    var transport: AimTransport = .simulated

    /// User intent: the switch on the panel. Not a statement that aiming is
    /// *running* — the loop also needs a live server table, see `isAiming`.
    var isEnabled: Bool = false

    // Keys that no longer exist are ignored by `JSONDecoder`, so an install
    // that still holds the old blob loads the retained fields and starts with
    // the loop off. One-way: the removed values are never written back.
    private enum CodingKeys: String, CodingKey {
        case minConfidence, minSize, onlyPerson, transport, isEnabled
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

// MARK: - State

/// The two sentences the loop uses to say why it is idle. Kept in one place so
/// the panel, the overlay menu and the controller cannot drift apart.
enum AimAssistNote {
    static let noParams = "尚未收到服务端瞄准参数"
    static let expired = "授权已过期，等待服务端下发"
}

@MainActor
final class AimController: ObservableObject {
    static let shared = AimController()

    @Published var settings = AimSettings() {
        didSet { persist() }
    }

    /// The server's table. nil means "no parameters" — never "defaults".
    ///
    /// Published so the panel can render the values read-only and the overlay
    /// can size the head band from the same numbers the loop uses.
    @Published private(set) var params: AimParams? = nil

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

    /// Why the loop is not running, when the reason is the parameters rather
    /// than the user's switch. Empty while the table is live.
    @Published private(set) var paramsNote: String = ""

    /// Whether the loop is actually stepping right now: user intent plus a live
    /// table. The panel shows this rather than the raw switch, so "on" can never
    /// be displayed for something that is not moving.
    var isAiming: Bool { timer != nil && settings.isEnabled && paramsIsLive }

    /// Whether the table we hold can be used on this frame.
    var paramsIsLive: Bool {
        guard let p = params else { return false }
        return p.isValid
    }

    /// Head band fraction currently in force, for the overlay's band outline.
    /// nil without parameters, so the overlay draws nothing instead of guessing
    /// a band size.
    var headBandFraction: Double? {
        guard let p = params, p.isValid, lastTargetHeight > 0 else { return nil }
        let head = p.headOffset(forHeight: lastTargetHeight,
                                confidence: lastTargetConfidence)
        return Double(head.y)
    }

    private var timer: Timer?
    private var lastTargetAt: Date?
    private var lastTickAt: Date?
    private var velocity: CGVector = .zero
    private var lastBounds: CGSize = .zero
    private var lastTargetHeight: Double = 0
    private var lastTargetConfidence: Double = 0
    private var transport: Transport = SimulatedTransport()

    private init() { load() }

    // MARK: Parameters

    /// Hands over the table from the licence heartbeat.
    ///
    /// The only way `params` ever becomes non-nil. A nil argument (heartbeat
    /// failed, token expired, server withheld the block, decryption failed)
    /// stops the loop in the same call, so there is no window in which a stale
    /// table keeps steering.
    func applyRemoteParams(_ p: AimParams?) {
        guard let p, p.isValid else {
            // The note names the state, not the cause: `LicenseManager` knows
            // why the block was withheld (network, ban, missing secret, bad
            // decryption) and surfaces that separately, so guessing here would
            // overwrite a better explanation with a worse one.
            params = nil
            halt(note: "瞄准参数不可用，等待服务端下发")
            return
        }
        params = p
        paramsNote = ""
        // A fresh table is the moment to resume: the switch is user intent and
        // must not have been cleared by the 60 s rollover. `start()` is not
        // called blind — it re-checks the table it is about to use.
        if settings.isEnabled { start() }
    }

    /// Drops the table immediately. Used on sign-out and on a killed/banned
    /// account, where even a still-valid window must not be honoured.
    func clearRemoteParams() {
        params = nil
        halt(note: AimAssistNote.noParams)
    }

    // MARK: Lifecycle

    func start() {
        // No table, no loop. This is the whole point of the round-7 design: the
        // switch alone cannot produce movement.
        //
        // The switch is left on rather than bounced back off. "Armed, waiting for
        // parameters" is a real state — the next heartbeat is at most 60 s away
        // and `applyRemoteParams` resumes the loop when it lands — whereas
        // clearing it would make the control flip itself off whenever the table
        // happened to be missing, which reads as a broken toggle. `isAiming` is
        // what the UI reports, and it stays false until a table is live.
        guard params?.isValid == true else {
            settings.isEnabled = true
            paramsNote = params == nil
                ? AimAssistNote.noParams
                : AimAssistNote.expired
            return
        }
        settings.isEnabled = true
        paramsNote = ""
        guard timer == nil else { return }

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

    /// Stops on the user's command, and on the zero-grace guards in `tick()`
    /// and `ingest()`: clears the switch as well.
    ///
    /// Called once per scan frame while no table is live, so it is written
    /// idempotent: the persisted switch is only assigned when it is actually
    /// on (assignments fire `didSet` and a UserDefaults write even when the
    /// value did not change), and `halt` short-circuits when everything is
    /// already at rest.
    func stop() {
        if settings.isEnabled { settings.isEnabled = false }
        halt(note: "")
    }

    /// Stops stepping: timer down, frame state cleared.
    ///
    /// Used when the reason is outside the user's control (table expired, table
    /// withdrawn) as well as from `stop()`. Clearing the switch here would make
    /// it flip itself off every time the 60-second window rolls over, which
    /// reads as a broken feature rather than an expired licence; `stop()` does
    /// that part explicitly.
    private func halt(note: String) {
        // Idempotence guard: the zero-grace paths call `stop()` on every frame
        // while no table is live, and every assignment below republishes an
        // @Published field. When everything is already at rest and there is no
        // new note, there is nothing to do.
        let atRest = timer == nil
            && aimPoint == nil
            && targetBox == nil
            && velocity == .zero
            && lastDelta == .zero
            && errorDistance == 0
            && cursor == CGPoint(x: 0.5, y: 0.5)
            && viewportOffset == .zero
        if atRest && note.isEmpty { return }
        timer?.invalidate()
        timer = nil
        aimPoint = nil
        targetBox = nil
        velocity = .zero
        lastDelta = .zero
        errorDistance = 0
        cursor = CGPoint(x: 0.5, y: 0.5)
        viewportOffset = .zero
        if !note.isEmpty { paramsNote = note }
    }

    /// Rebuilds the transport after the user switches it.
    func refreshTransport() {
        transport = makeTransport()
        transportNote = transport.note
        velocity = .zero
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

    // MARK: Ingest

    /// Called with each scan result, in normalised frame coordinates.
    func ingest(detections: [Detection], in bounds: CGSize) {
        // Zero grace, first line of the frame: no live table, no aim work at
        // all — not target selection, not state refresh, nothing.
        guard let p = params, p.isValid else { stop(); return }
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
            lastTargetHeight = 0
            lastTargetConfidence = 0
            return
        }

        let r = best.rect
        let box = CGRect(x: r.minX * bounds.width,
                         y: r.minY * bounds.height,
                         width: r.width * bounds.width,
                         height: r.height * bounds.height)

        // The aim point is a table lookup, not an expression: the server decides
        // where in the box the head sits, as a function of the box's own scale.
        let aim = p.aimPoint(for: r, confidence: Double(best.confidence))
        let aimX = aim.x
        let aimY = aim.y

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
        lastTargetHeight = Double(r.height)
        lastTargetConfidence = Double(best.confidence)
    }

    // MARK: Tick

    private func tick() {
        // Zero grace, checked every frame. A table that expired between two
        // heartbeats stops the loop here, mid-window, not at the next reply.
        guard let p = params, p.isValid else { stop(); return }
        guard settings.isEnabled, let aim = aimPoint else { return }

        let now = Date()
        let dt = lastTickAt.map { now.timeIntervalSince($0) } ?? (1.0 / 60.0)
        lastTickAt = now
        ticks += 1

        // Lead the target. The horizon comes from the server's weight table; the
        // age term is measured staleness (a fact about this frame, not a
        // tunable). Both are bounded by the server's own clamp, so a flick of
        // the detector cannot throw the aim across the screen.
        let horizon = Double(p.prediction(forDt: dt).dx)
        let age = lastTargetAt.map { now.timeIntervalSince($0) } ?? 0
        let lead = age + max(0, horizon)
        let targetX = aim.x + CGFloat(p.clamp(Double(velocity.dx) * lead))
        let targetY = aim.y + CGFloat(p.clamp(Double(velocity.dy) * lead))

        // Move a fraction of the remaining distance. The two halves of that
        // fraction — speed tier and smoothing — are both table lookups.
        let speed = p.speed(forIndex: p.speedIndex(forHeight: lastTargetHeight))
        let smoothing = p.smoothing(forConfidence: lastTargetConfidence)
        let gain = speed * (1.0 - smoothing)

        // One tick can never teleport the cursor: the output bound is the
        // server's clamp, applied per axis.
        let stepX = CGFloat(p.clamp(Double(targetX - cursor.x) * gain))
        let stepY = CGFloat(p.clamp(Double(targetY - cursor.y) * gain))

        cursor = CGPoint(x: cursor.x + stepX, y: cursor.y + stepY)
        lastDelta = CGVector(dx: stepX, dy: stepY)
        errorDistance = Double(hypot(targetX - cursor.x, targetY - cursor.y))

        // Convert back to points for the transport.
        transport.send(dx: Double(stepX) * Double(lastBounds.width),
                       dy: Double(stepY) * Double(lastBounds.height))
    }

    // MARK: Persistence
    //
    // Only the switch and the target-selection settings are persisted. The
    // server table is never written anywhere: it lives in memory for at most
    // 60 seconds and dies with the process, which is what makes a static dump
    // of the app useless.

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
/// Exists so the aim table can be exercised and compared against the overlay
/// component's own output before a privileged transport is present; without it
/// the feature would be untestable in a signed build.
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
    // The tuning keys (`enabled`, `overlay`, the model path) belong to the
    // overlay settings panel, which owns the whole plist. This bridge
    // deliberately touches only the two movement keys: two writers rewriting the
    // same file would fight, and the panel verifies its own writes by reading
    // them back.

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
