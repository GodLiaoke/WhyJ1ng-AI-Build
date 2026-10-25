import Foundation

// MARK: - Device capability
//
// The single source of truth for "what can this device actually do".
//
// Every privileged feature is offered through this type: the launch mode picker,
// the kernel gate and the aim transport all ask here first. Nothing gets
// promised that the probes below did not observe on this exact build.
//
// Everything is a synchronous static property on purpose. Call sites are SwiftUI
// body evaluation, the exploit runner and background callbacks; an async probe
// would force every one of them into a Task and could still answer with a stale
// value at the worst moment. The file-system probes are trivial and their
// results are cached in `Probe`, with one exception: the overlay heartbeat is
// re-read on every access, because freshness is the whole point of it.
//
// None of the probes may throw or crash. A probe that fails is simply `false`.

enum DeviceCapability {

    // MARK: - Paths shared with the SpringBoard component
    //
    // These three paths are the App/dylib contract. The App writes the first,
    // the dylib writes the second, and the third is the Darwin notification the
    // App posts after a write.

    static let overlayConfigPath = "/var/mobile/Library/Preferences/cc.ouovo.yolooverlay.plist"
    static let overlayHeartbeatPath = "/var/mobile/Library/Preferences/cc.ouovo.yolooverlay.alive"
    static let overlayReloadNotification = "cc.ouovo.yolooverlay.reload"

    // MARK: - Version

    /// "26.0.1" — patch is dropped when it is zero, so 16.6 stays "16.6".
    static var osVersion: String { Probe.osVersion }

    /// "16.6" — what the vulnerability window comparisons use.
    static var osMajorMinor: String { Probe.osMajorMinor }

    /// "16.6.0" — always three components, for logs and diagnostics.
    static var osVersionFull: String { Probe.osVersionFull }

    // MARK: - Environment

    /// Jailbreak: known artifacts, or a process that can write outside its
    /// sandbox while showing no TrollStore-only signature.
    static var isJailbroken: Bool { Probe.isJailbroken }

    /// Installed through TrollStore rather than the App Store or a sideload.
    static var isTrollStore: Bool { Probe.isTrollStore }

    /// Not confined by the app sandbox. True for jailbroken and TrollStore
    /// builds alike — this says nothing about which one it is.
    static var isUnsandboxed: Bool { Probe.isUnsandboxed }

    // MARK: - Capabilities

    /// kfd-class kernel window: iOS 14.0 through 16.6 inclusive.
    ///
    /// 16.6.1 closed the bug and every later build needs offsets that cannot be
    /// synthesised, so the window ends at 16.6.0 exactly.
    static var supportsKernelExploit: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard isDevice else { return false }
        let v = Probe.version
        if v.major < 14 || v.major > 16 { return false }
        if v.major < 16 { return true }
        if v.minor < 6 { return true }
        if v.minor > 6 { return false }
        return v.patch == 0
        #endif
    }

    /// Touches injected into another app's input stream via IOHIDEvent.
    ///
    /// Only needs a jailbreak — no kernel primitive involved.
    static var supportsTouchInjection: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return isDevice && isJailbroken
        #endif
    }

    /// Window drawn inside SpringBoard, i.e. it survives app switching.
    ///
    /// Achievable whenever side-loaded code can be injected into SpringBoard,
    /// which needs a jailbreak. The component still has to be installed; check
    /// `systemOverlayLoaded` before claiming it is running.
    static var supportsSystemOverlay: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return isDevice && isJailbroken
        #endif
    }

    /// Picture-in-picture: iOS 15 and later.
    static var supportsPiP: Bool { Probe.version.major >= 15 }

    /// Whether the SpringBoard component is alive right now.
    ///
    /// The component stamps the heartbeat file every 5 seconds, so a stamp
    /// inside the server's window means it is running. The window used to be
    /// hard-coded at 15 s; it is now `dylib_check.heartbeat_window_sec`, which
    /// is 10 s unless an operator widened or narrowed it.
    ///
    /// Not cached: this is the one answer that legitimately changes while the
    /// app is open.
    static var systemOverlayLoaded: Bool {
        guard let age = heartbeatAge else { return false }
        // A stamp slightly in the future is tolerated: the only writer is the
        // component on this same device, so any skew is rounding, not a clock
        // disagreement. A stale stamp is not tolerated — that is the signal.
        return age >= -5 && age <= heartbeatWindowSec
    }

    /// Seconds since the component last stamped the heartbeat file.
    ///
    /// nil when the file has never been written, which is a different state
    /// from "written long ago" and has to stay distinguishable: the first means
    /// the driver was never installed, the second means it stopped.
    ///
    /// The bridge comes first on purpose. A sandboxed app cannot read
    /// `/var/mobile/Library/Preferences/`, which is where the component writes
    /// the primary stamp — so reading that path directly reports "never
    /// installed" on a jailbroken device where the driver is running fine.
    /// The component mirrors the stamp into this app's Documents directory, and
    /// only `YOHeartbeatAge` in the dylib walks all three locations
    /// (preferences, legacy preferences, Documents mirror). Asking it is the
    /// only way to see the mirror.
    static var heartbeatAge: Double? {
        if AuthCoreBridge.isAvailable {
            let bridged = AuthCoreBridgeSystemHeartbeatAge()
            if bridged >= 0 {
                return bridged
            }
        }
        guard let stamp = heartbeatTimestamp else { return nil }
        return Date().timeIntervalSince1970 - stamp
    }

    /// One line for the UI, e.g.
    /// "iOS 26.0.1 · 已越狱 · 可注入点击 · 无内核注入 · 悬浮组件未安装"
    static var summary: String {
        var parts: [String] = ["iOS \(osVersion)"]

        if isJailbroken {
            parts.append("已越狱")
        } else if isTrollStore {
            parts.append("未越狱 · TrollStore")
        } else {
            parts.append("未越狱")
        }

        parts.append(supportsTouchInjection ? "可注入点击" : "不可注入点击")
        parts.append(supportsKernelExploit ? "内核注入可用" : "无内核注入")

        if supportsSystemOverlay {
            parts.append(systemOverlayLoaded ? "悬浮组件运行中" : "悬浮组件未安装")
        } else {
            parts.append("仅本 App 内悬浮")
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - Driver check policy
    //
    // The server decides whether the App looks for the driver at all
    // (`dylib.verify`), whether the verdict is strict
    // (`dylib.verify.strict`) and what counts as a fresh heartbeat
    // (`dylib.heartbeat_sec`). `LicenseManager` writes the policy here on every
    // heartbeat, so every other file can read one synchronous answer without
    // knowing that a network exists.
    //
    // The storage is a mutable static behind a lock rather than a `static let`
    // because it genuinely changes at runtime, and reads happen from SwiftUI
    // body evaluation, background callbacks and the exploit runner alike.

    private static let driverLock = NSLock()
    private static var driverPolicyStored = DriverPolicy()

    static var driverPolicy: DriverPolicy {
        driverLock.lock()
        defer { driverLock.unlock() }
        return driverPolicyStored
    }

    static func setDriverPolicy(_ policy: DriverPolicy) {
        driverLock.lock()
        driverPolicyStored = policy
        driverLock.unlock()

        // Push the switch into the dylib as well. Enforcement lives in C and used
        // to read only the jailbreak check, so turning the server switch off had
        // no effect on the exit gate or on the component's licence round trip.
        // Done every time, including when the policy says "do not check", because
        // that transition is the one that has to take effect.
        AuthCoreBridgeSetDriverEnforcement(policy.enabled)
    }

    /// Window inside which a heartbeat counts as fresh. Defaults to 10 s, which
    /// is also the server default; it was 15 s hard-coded before the policy was
    /// server-driven.
    static var heartbeatWindowSec: Double { driverPolicy.heartbeatWindowSec }

    // MARK: - Driver readiness

    /// Why the driver is, or is not, usable — one specific reason, never a bare
    /// "not ready".
    ///
    /// When the server switch is off this answers `.disabled` and the caller is
    /// expected to hide the whole status block: the user did not enable driver
    /// checking and must not be nagged about a driver they never asked for.
    static var driverProblem: DriverProblem {
        let policy = driverPolicy

        // First, before any probe: with the switch off there is nothing to be
        // missing. Reporting "driver not installed" for a check an operator
        // turned off would be a fault the user cannot act on.
        guard policy.enabled else { return .disabled }

        // 1. Heartbeat freshness.
        guard let age = heartbeatAge else { return .noHeartbeat }
        if age > policy.heartbeatWindowSec || age < -5 {
            return .staleHeartbeat(age: age)
        }

        // Non-strict stops at "the component is running". Strict also demands
        // the component's own licence verdict and a version new enough. The
        // default is strict.
        guard policy.strict else { return .none }

        // 2. The component checks the card itself, against its own endpoint, so
        // a patched App-side answer does not survive. A component built before
        // the symbol exists reports false here, and false reads as "not
        // verified" — never as a silent pass.
        guard AuthCoreBridge.licenseValid else { return .licenseInvalid }

        // 3. Version match, segment by segment ("1.10.0" > "1.9.0").
        let installed = AuthCoreBridge.dylibVersion
        let required = policy.componentLatest
        if !required.isEmpty, VersionCompare.isNewer(required, than: installed) {
            return .versionMismatch(installed: installed, required: required)
        }

        return .none
    }

    // MARK: - Heartbeat

    /// The timestamp the overlay component last wrote, or nil when absent.
    static var heartbeatTimestamp: Double? {
        guard let raw = try? String(contentsOfFile: overlayHeartbeatPath, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed) else { return nil }
        // Anything absurd predates the component by years; treat as absent.
        return value > 1_500_000_000 ? value : nil
    }

    // MARK: - Internals

    private static var isDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    /// Lazily initialised probe results. Swift initialises a static `let` once,
    /// on first use, and guarantees thread safety, so these are safe to read
    /// from any context without a lock of our own.
    private enum Probe {

        static let version: (major: Int, minor: Int, patch: Int) = {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return (v.majorVersion, v.minorVersion, v.patchVersion)
        }()

        static let osVersionFull = "\(Probe.version.major).\(Probe.version.minor).\(Probe.version.patch)"

        static let osVersion: String = Probe.version.patch == 0
            ? "\(Probe.version.major).\(Probe.version.minor)"
            : "\(Probe.version.major).\(Probe.version.minor).\(Probe.version.patch)"

        static let osMajorMinor = "\(Probe.version.major).\(Probe.version.minor)"

        /// Artifacts left behind by a jailbreak on device. Rootless (Dopamine,
        /// palera1n) puts everything under /var/jb, so the legacy paths alone
        /// are not enough on modern systems.
        static let jailbreakArtifactPaths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/usr/sbin/sshd",
            "/var/jb",
            "/usr/lib/libellekit.dylib",
            "/var/lib/dpkg",
        ]

        /// True when the process can write a file outside its own container.
        /// A sandboxed app cannot, whatever entitlements it carries, so this is
        /// the strongest single signal available without a jailbreak-specific
        /// API. The probe file is removed again immediately.
        static let isUnsandboxed: Bool = {
            #if targetEnvironment(simulator)
            return false
            #else
            let probePath = "/var/mobile/Library/Preferences/.cc.ouovo.yolo.sandboxprobe"
            do {
                try "probe".write(toFile: probePath, atomically: true, encoding: .utf8)
            } catch {
                return false
            }
            _ = try? FileManager.default.removeItem(atPath: probePath)
            return true
            #endif
        }()

        static let hasJailbreakArtifact: Bool = {
            let fm = FileManager.default
            for path in Probe.jailbreakArtifactPaths {
                if fm.fileExists(atPath: path) { return true }
            }
            return false
        }()

        /// TrollStore signals: its own preferences file, or a bundle that sits
        /// in the system application container while carrying no code
        /// signature seal — the ldid signature TrollStore installs with.
        static let isTrollStore: Bool = {
            let fm = FileManager.default
            let marker = "/var/mobile/Library/Preferences/com.opa334.TrollStore.plist"
            if fm.fileExists(atPath: marker) { return true }

            let bundlePath = Bundle.main.bundlePath
            guard bundlePath.contains("/var/containers/Bundle/Application/") else { return false }
            let seal = bundlePath + "/_CodeSignature/CodeResources"
            return !fm.fileExists(atPath: seal)
        }()

        /// An unsandboxed process with no jailbreak artifact and a TrollStore
        /// signature is a TrollStore install, not a jailbroken device. Keeping
        /// the two apart matters: TrollStore alone cannot inject into
        /// SpringBoard, so calling it "jailbroken" would re-create exactly the
        /// false promise this file exists to remove.
        static let isJailbroken: Bool = {
            #if targetEnvironment(simulator)
            return false
            #else
            if Probe.hasJailbreakArtifact { return true }
            return Probe.isUnsandboxed && !Probe.isTrollStore
            #endif
        }()
    }
}

// MARK: - Driver check policy value

/// The server's driver-check policy, as a plain value.
///
/// Defaults describe an App that has not heard from the server yet: `enabled`
/// is false, because the requirement is that nothing is checked until the
/// server says so. The first heartbeat replaces it within a second.
struct DriverPolicy: Equatable {

    /// False means "do not look for the driver at all".
    var enabled: Bool = false

    /// True means heartbeat + the component's own licence verdict + a version
    /// match; false stops at the heartbeat.
    var strict: Bool = false

    /// Version the component has to reach (`dylib_check.component_latest`).
    var componentLatest: String = ""

    /// A heartbeat older than this is stale.
    var heartbeatWindowSec: Double = DriverPolicy.defaultWindowSec

    /// 10 s. The heartbeat file is stamped every 5 s, so this tolerates one
    /// missed stamp and nothing more.
    static let defaultWindowSec: Double = 10

    /// Same clamp the server applies before sending the value. Applied again
    /// here so a malformed payload cannot widen the window into a de-facto
    /// always-fresh verdict.
    static func clampWindow(_ raw: Double) -> Double {
        if !raw.isFinite { return defaultWindowSec }
        if raw < 3 { return 3 }
        if raw > 120 { return 120 }
        return raw
    }
}

// MARK: - Driver problem

/// Why the driver is, or is not, ready. `.none` is the only ready state.
///
/// Each case carries what the user needs to fix it, because "not ready" on its
/// own is unactionable: a component that was never installed, one that stopped
/// responding, one that is too old and one that failed its own licence check
/// are four different jobs.
enum DriverProblem: Equatable {
    case none
    /// The server turned driver checking off; hide the status entirely.
    case disabled
    /// The heartbeat file has never been written: the driver is not installed.
    case noHeartbeat
    /// Written, but too long ago — the component stopped.
    case staleHeartbeat(age: Double)
    case versionMismatch(installed: String, required: String)
    /// The component could not verify the card on its own.
    case licenseInvalid

    var isReady: Bool { self == .none }

    /// Whether the UI should show a status block at all.
    var isVisible: Bool { self != .disabled }

    /// One sentence for the dashboard.
    var message: String {
        switch self {
        case .none:
            return "驱动已就绪"
        case .disabled:
            return "服务端未开启驱动检测"
        case .noHeartbeat:
            return "未检测到驱动，请安装驱动后重试"
        case .staleHeartbeat(let age):
            return String(format: "驱动已停止响应（上次心跳 %.0f 秒前），请重启设备或重新注入驱动",
                          max(0, age))
        case .versionMismatch(let installed, let required):
            return "驱动版本过旧（当前 \(installed)，需要 \(required)），请更新驱动"
        case .licenseInvalid:
            return "驱动未通过独立鉴权，请在驱动内重新验证卡密"
        }
    }
}

