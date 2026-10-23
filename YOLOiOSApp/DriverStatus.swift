import Combine
import Foundation
import SwiftUI

// MARK: - Driver state
//
// The dashboard's answer to "is the driver running". The user facing word for the
// SpringBoard component is "driver" (驱动); the code keeps saying dylib /
// AuthCore because that is what the artefact actually is.
//
// Four states only, so no view ever has to guess what to draw:
//
//   unknown   nothing probed yet, or the probe has not finished
//   disabled  the server switched the check off - the block must not render
//   ready     heartbeat fresh + version current + the driver's own check passed
//   notReady  one of the three failed, and the reason says which one
//
// The policy itself is not decided here: `LicenseManager` writes the server's
// answer into `DeviceCapability.driverPolicy` on every heartbeat. This type reads
// that and turns it into a sentence.

enum DriverState: Equatable {
    case unknown
    case disabled
    case ready(version: String, ageSec: Double)
    case notReady(reason: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// True when the whole block has to stay off screen.
    ///
    /// Only `.unknown` is hidden now. `.disabled` used to hide too, which meant an
    /// operator who turned the check off made the feature invisible with no way to
    /// tell it existed - the block simply vanished and the switch looked broken.
    /// It now renders in a muted state that says so.
    var isHidden: Bool {
        switch self {
        case .unknown:
            return true
        case .disabled, .ready, .notReady:
            return false
        }
    }

    /// Animation identity. The age inside `ready` changes every few seconds and
    /// must not re-run an insertion transition, so transitions key on the kind.
    var kind: String {
        switch self {
        case .unknown:  return "unknown"
        case .disabled: return "disabled"
        case .ready:    return "ready"
        case .notReady: return "notReady"
        }
    }
}

// MARK: - Status model

@MainActor
final class DriverStatus: ObservableObject {

    static let shared = DriverStatus()

    @Published private(set) var state: DriverState = .unknown

    /// True while a probe is in flight. Only observable for a manual refresh,
    /// which holds the flag long enough for one frame to show it.
    @Published private(set) var checking = false

    /// What the last probe judged against, so the card can quote the window.
    @Published private(set) var policy: DriverPolicy = DriverPolicy()

    /// Number of views currently asking for updates. Counting rather than
    /// setting a flag matters: during a tab switch the new view's onAppear can
    /// run before the old view's onDisappear, and a plain flag would leave the
    /// poll cancelled while a card is still on screen claiming to be fresh.
    private var observers = 0
    private var poll: Task<Void, Never>?

    private init() {}

    // MARK: Lifetime

    /// Starts (or joins) the polling loop. Idempotent per caller.
    func activate() {
        observers += 1
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            }
        }
    }

    func deactivate() {
        observers = max(0, observers - 1)
        guard observers == 0 else { return }
        poll?.cancel()
        poll = nil
    }

    // MARK: Probe

    /// Re-probes every input and republishes the verdict.
    ///
    /// Cheap on purpose: one file read and a handful of C calls. The loop calls
    /// it every 3 s, which is what keeps "heartbeat 4 s ago" honest instead of
    /// frozen at launch.
    func refresh(manual: Bool = false) async {
        checking = true
        let current = DeviceCapability.driverPolicy
        policy = current
        let next = evaluate(current)
        if manual {
            try? await Task.sleep(nanoseconds: 260_000_000)
        }
        state = next
        checking = false
    }

    // MARK: Verdict

    private func evaluate(_ p: DriverPolicy) -> DriverState {
        // The server owns whether this is checked at all. Off means the user
        // never asked for it and must not be nagged; the whole block hides.
        guard p.enabled else { return .disabled }

        let window = p.heartbeatWindowSec > 0 ? p.heartbeatWindowSec : DriverPolicy.defaultWindowSec

        // The component is a separate copy injected into SpringBoard, but the
        // same build also ships inside this bundle. Nothing loaded here means the
        // install itself is broken, which is a different sentence from "the
        // component is not running".
        guard AuthCoreBridge.isAvailable else {
            return .notReady(reason: "驱动组件未加载：本机没有可用的驱动文件，请重新安装")
        }

        let version = AuthCoreBridge.dylibVersion
        let age = heartbeatAge()
        guard age >= 0 else {
            return .notReady(reason: "驱动未运行：没有任何心跳记录，驱动可能没有安装或没有启动")
        }
        if age > window {
            return .notReady(reason: "心跳已过期：最后一次心跳在 \(Int(age.rounded())) 秒前，要求 \(Int(window)) 秒内")
        }

        // Non-strict stops at "the component is running". Strict also demands the
        // component's own licence verdict and a version new enough.
        guard p.strict else {
            return .ready(version: version, ageSec: age)
        }

        // The driver runs its own licence check against its own endpoint, so a
        // patched App-side verdict does not survive.
        if !AuthCoreBridgeLicenseValid() {
            return .notReady(reason: licenseProblem())
        }

        let required = p.componentLatest
        if !required.isEmpty, !versionAtLeast(version, required) {
            return .notReady(reason: "驱动版本过旧：当前 \(version)，需要 \(required)")
        }

        return .ready(version: version, ageSec: age)
    }

    /// Seconds since the component last stamped its heartbeat, or -1 when it
    /// never did.
    ///
    /// The C bridge is asked first: it walks every heartbeat path, including the
    /// copy the component mirrors into this app's Documents folder. That mirror is
    /// the only one a sandboxed reader can see, so a filesystem probe that only
    /// knows `/var/mobile/...` would report "never installed" for a driver that is
    /// running perfectly well.
    private func heartbeatAge() -> Double {
        let bridged = AuthCoreBridgeSystemHeartbeatAge()
        if bridged >= 0 { return bridged }
        if let stamp = DeviceCapability.heartbeatTimestamp {
            let age = Date().timeIntervalSince1970 - stamp
            return age >= 0 ? age : 0
        }
        return -1
    }

    /// Why the driver's own licence check did not pass, in the component's own
    /// result codes.
    private func licenseProblem() -> String {
        switch AuthCoreBridgeLastLicenseResult() {
        case -1:
            return "独立鉴权未通过：驱动连不上验证服务器"
        case -2:
            return "独立鉴权未通过：驱动认为这张卡密无效"
        case -3:
            return "独立鉴权未通过：驱动的配置或签名校验失败"
        case -4:
            return "独立鉴权未通过：服务器拒绝了驱动的校验请求"
        default:
            let age = AuthCoreBridgeLicenseAge()
            if age < 0 {
                return "独立鉴权未完成：驱动还没有自己校验过授权，请重新激活后启动驱动"
            }
            return "独立鉴权已过期：驱动最近一次校验在 \(Int(age)) 秒前"
        }
    }

    /// Segment-wise compare, so "1.10.0" is not ranked below "1.9.0".
    private func versionAtLeast(_ current: String, _ required: String) -> Bool {
        let a = numericSegments(current)
        let b = numericSegments(required)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    private func numericSegments(_ version: String) -> [Int] {
        let core = version.split(separator: "-", maxSplits: 1).first ?? ""
        return core.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
    }
}

// MARK: - Dashboard block
//
// A solid card, deliberately: the glass surface is for the top bar and sheets,
// and this block sits in the middle of a data-dense column where a translucent
// background reads as noise.
//
//   ready     green, one slow pulse, version + heartbeat age
//   notReady  amber, the exact condition that failed, install steps on demand
//   disabled  muted grey - the server turned the check off, said plainly

struct DriverStatusCard: View {

    @ObservedObject private var driver = DriverStatus.shared
    @State private var expanded = false

    var body: some View {
        Group {
            switch driver.state {
            case .ready(let version, let age):
                readyCard(version: version, age: age)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97)),
                        removal: .opacity))

            case .notReady(let reason):
                notReadyCard(reason: reason)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity))

            case .disabled:
                disabledCard
                    .transition(.opacity)

            case .unknown:
                EmptyView()
            }
        }
        .animation(DS.Motion.spring, value: driver.state.kind)
    }

    // MARK: Disabled

    /// Shown when the server has switched the check off.
    ///
    /// Deliberately still visible: hiding it made the feature disappear entirely,
    /// so there was no way to tell whether the driver was absent, broken, or
    /// simply not being looked for. Muted, not alarming - nothing is wrong.
    private var disabledCard: some View {
        shell(tint: Palette.inkTertiary, border: Palette.inkTertiary.opacity(0.18)) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Palette.inkTertiary)
                    .frame(width: 10)

                VStack(alignment: .leading, spacing: 5) {
                    Text("驱动检测已关闭")
                        .font(DS.Font.headline)
                        .foregroundColor(Palette.inkSecondary)

                    Text("服务端当前不要求安装驱动，客户端不会去检测。功能本身仍可用，装驱动后可恢复系统级悬浮。")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Ready

    private func readyCard(version: String, age: Double) -> some View {
        shell(tint: Palette.success, border: Palette.success.opacity(0.28)) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                PulseDot(tint: Palette.success, soft: Palette.successSoft)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: DS.Space.s) {
                        Text("驱动就绪")
                            .font(DS.Font.headline)
                            .foregroundColor(Palette.ink)
                        Spacer(minLength: 0)
                        versionChip(version, tint: Palette.success,
                                    background: Palette.successSoft)
                    }

                    Text(readyDetail(age: age))
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkSecondary)
                }
            }
        }
    }

    /// Only claims the independent check when strict mode actually ran it.
    private func readyDetail(age: Double) -> String {
        let seconds = Int(age.rounded())
        if driver.policy.strict {
            return "\(seconds) 秒前心跳 · 独立鉴权通过"
        }
        return "\(seconds) 秒前心跳"
    }

    // MARK: Not ready

    private func notReadyCard(reason: String) -> some View {
        shell(tint: Palette.warning, border: Palette.warning.opacity(0.32)) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    WarningDot()

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: DS.Space.s) {
                            Text("驱动未就绪")
                                .font(DS.Font.headline)
                                .foregroundColor(Palette.ink)
                            Spacer(minLength: 0)
                            Text("需要处理")
                                .font(DS.Font.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(Palette.warning)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Palette.warningSoft))
                        }

                        Text(reason)
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Hairline()

                Button {
                    withAnimation(DS.Motion.spring) { expanded.toggle() }
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 12, weight: .semibold))
                        Text("如何安装驱动")
                            .font(DS.Font.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .foregroundColor(Palette.warning)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        ForEach(Array(installSteps.enumerated()), id: \.offset) { idx, text in
                            HStack(alignment: .top, spacing: DS.Space.s) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: 15, height: 15)
                                    .background(Circle().fill(Palette.warning.opacity(0.85)))
                                Text(text)
                                    .font(DS.Font.caption)
                                    .foregroundColor(Palette.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Text("驱动每 5 秒写一次心跳，超过 \(Int(driver.policy.heartbeatWindowSec)) 秒没更新就判为未就绪。")
                            .font(.system(size: 10))
                            .foregroundColor(Palette.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var installSteps: [String] {
        [
            "确认设备已越狱：驱动要注入系统进程，TrollStore 单独安装做不到这一点。",
            "在官网用卡密换一次性下载链接，拿到驱动包后装进设备。",
            "安装完成后注销一次或重启桌面，让驱动开始往系统里写心跳。",
            "回到首页等几秒，状态会自动刷新，不需要重开 App。",
        ]
    }

    // MARK: Shell

    private func shell<Content: View>(tint: Color,
                                      border: Color,
                                      @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint)
                    .frame(width: 3)
                    .padding(.vertical, DS.Space.m)
                    .padding(.leading, 1)
            }
            .shadow(color: Palette.shadow, radius: 8, x: 0, y: 3)
    }

    private func versionChip(_ version: String, tint: Color, background: Color) -> some View {
        Text("v\(version)")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
    }
}

// MARK: - Dots

/// A restrained pulse: one ring expanding and fading, one dot breathing.
///
/// The two run on separate state so the ring can restart while the dot keeps a
/// smooth back-and-forth; sharing one flag made the ring snap between cycles,
/// which read as a glitch rather than a heartbeat.
private struct PulseDot: View {
    var tint: Color
    var soft: Color

    @State private var ring = false
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.45), lineWidth: 1.2)
                .frame(width: 15, height: 15)
                .scaleEffect(ring ? 1.9 : 0.75)
                .opacity(ring ? 0 : 0.75)

            Circle()
                .fill(soft)
                .frame(width: 24, height: 24)

            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .scaleEffect(breathe ? 1.12 : 0.88)
                .opacity(breathe ? 1 : 0.7)
        }
        .frame(width: 26, height: 24)
        .onAppear {
            withAnimation(.easeOut(duration: 1.9).repeatForever(autoreverses: false)) {
                ring = true
            }
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

/// Static amber marker: a fault is not an occasion for animation, and a pulsing
/// error would fight for attention every time the dashboard is opened.
private struct WarningDot: View {
    var body: some View {
        ZStack {
            Circle().fill(Palette.warningSoft).frame(width: 24, height: 24)
            Circle().fill(Palette.warning).frame(width: 8, height: 8)
        }
        .frame(width: 26, height: 24)
    }
}
