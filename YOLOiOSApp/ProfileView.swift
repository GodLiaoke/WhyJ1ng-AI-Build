import SwiftUI
import UIKit

// MARK: - Profile
//
// Everything the user owns: who they are on this device, what their card
// unlocks, and when it runs out.

struct ProfileView: View {
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var app = AppState.shared

    @State private var refreshing = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                identityCard
                if !license.mainAnnouncements.isEmpty {
                    AnnouncementList(announcements: license.mainAnnouncements)
                }
                permissionSection
                runtimeSection
                sessionSection
                aboutSection
                CopyrightBanner()
                Color.clear.frame(height: MainTabView.barFootprint)
            }
            .padding(DS.Space.l)
        }
        .background(Palette.canvas)
        // iOS 15 form of the alert. The `Alert(title:message:primaryButton:)`
        // initialiser is deprecated as of 15, and the deprecated spelling shows
        // up as a warning in every CI log, which is how real warnings get
        // missed.
        .alert("退出登录？", isPresented: $confirmingSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) { performSignOut() }
        } message: {
            Text(Self.signOutWarning)
        }
    }

    // MARK: Identity

    private var identityCard: some View {
        SurfaceCard(padding: DS.Space.l, elevated: true) {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(spacing: DS.Space.m) {
                    ZStack {
                        Circle().fill(levelColor.opacity(0.15)).frame(width: 54, height: 54)
                        Text(initial)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(levelColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(license.nickname.isEmpty ? "未命名" : license.nickname)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(Palette.ink)
                        HStack(spacing: 6) {
                            Text(license.levelName.uppercased())
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(levelColor))
                            if license.level >= 1 {
                                Text("BETA")
                                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                    .foregroundColor(Color(red: 0.024, green: 0.714, blue: 0.831))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(Color(red: 0.024, green: 0.714, blue: 0.831).opacity(0.14))
                                    )
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                Hairline()

                VStack(spacing: DS.Space.s) {
                    InfoRow(label: "到期时间", value: expiryText, mono: true)
                    InfoRow(label: "设备号", value: String(license.deviceId.prefix(16)) + "…", mono: true)
                    InfoRow(label: "授权状态", value: stateText)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task {
                        refreshing = true
                        await license.refresh()
                        await license.loadAnnouncements(place: "main")
                        refreshing = false
                    }
                } label: {
                    HStack(spacing: DS.Space.s) {
                        if refreshing {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(refreshing ? "刷新中" : "刷新授权")
                    }
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                            .fill(Palette.accentSoft.opacity(0.7))
                    )
                }
                .buttonStyle(.plain)
                .disabled(refreshing)
            }
        }
    }

    private var initial: String {
        let n = license.nickname.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "?" : String(n.prefix(1)).uppercased()
    }

    private var levelColor: Color {
        // One colour per tier, matching the badge palette used elsewhere.
        switch license.level {
        case 4:  return Color(red: 0.545, green: 0.361, blue: 0.965)
        case 3:  return Color(red: 0.231, green: 0.510, blue: 0.965)
        case 2:  return Color(red: 0.063, green: 0.725, blue: 0.506)
        case 1:  return Color(red: 0.024, green: 0.714, blue: 0.831)
        default: return Palette.inkTertiary
        }
    }

    private var expiryText: String {
        if let e = license.expiresAt, !e.isEmpty {
            return e
        }
        return "永久有效"
    }

    private var stateText: String {
        switch license.state {
        case .active: return "正常"
        case .maintenance: return "维护中（功能受限）"
        case .expired: return "已过期"
        case .banned(let r): return "已封禁 \(r)"
        case .killed(let r): return "已停用 \(r)"
        case .networkError: return "无法连接验证服务器"
        default: return "未激活"
        }
    }

    // MARK: Permissions
    //
    // The same list the gate consults, shown so a locked feature explains
    // itself instead of just refusing.

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "我的权限", systemImage: "checkmark.shield")

            SurfaceCard(padding: DS.Space.xs) {
                if license.gates.isEmpty {
                    Text("暂无权限数据，下拉刷新试试。")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                        .padding(DS.Space.m)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(license.gates.enumerated()), id: \.element.feature) { idx, g in
                            HStack(spacing: DS.Space.m) {
                                Image(systemName: g.unlocked ? "checkmark.circle.fill"
                                                             : "lock.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(g.unlocked ? Palette.success
                                                                : Palette.inkTertiary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(g.label)
                                        .font(DS.Font.body)
                                        .foregroundColor(g.unlocked ? Palette.ink
                                                                    : Palette.inkSecondary)
                                    if !g.unlocked {
                                        Text("需要 \(LicenseManager.levelDisplayName(g.minLevel))"
                                             + (g.needsBeta ? " · 内测权限" : ""))
                                            .font(.system(size: 10))
                                            .foregroundColor(Palette.inkTertiary)
                                    }
                                }
                                Spacer(minLength: 0)

                                if g.needsBeta && g.unlocked {
                                    Text("BETA")
                                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                        .foregroundColor(levelColor)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(levelColor.opacity(0.13)))
                                }
                            }
                            .padding(.horizontal, DS.Space.m)
                            .padding(.vertical, 10)

                            if idx < license.gates.count - 1 {
                                Hairline().padding(.leading, 44)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Runtime
    //
    // Only what a user can act on. Compute-unit and network-access rows were
    // removed: they are implementation detail, not information.

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "运行环境", systemImage: "cpu")

            SurfaceCard(padding: DS.Space.xs) {
                VStack(spacing: 0) {
                    row("机型", LicenseDevice.modelName)
                    Hairline()
                    row("系统版本", "iOS \(LicenseDevice.systemVersion)")
                    Hairline()
                    row("设备号", license.deviceId, mono: true, lines: 2)
                    Hairline()
                    row("应用版本", "\(LicenseDevice.appVersion) (\(LicenseDevice.buildNumber))")
                    Hairline()
                    row("驱动版本", AuthCoreBridge.isAvailable
                        ? "v\(AuthCoreBridge.dylibVersion)" : "未安装")
                    Hairline()
                    row("发布通道", AppBrand.channel)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String,
                     mono: Bool = false, lines: Int = 1) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(DS.Font.body)
                .foregroundColor(Palette.inkSecondary)
            Spacer(minLength: DS.Space.m)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : DS.Font.body)
                .foregroundColor(Palette.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(lines)
                .truncationMode(.middle)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 11)
    }

    // MARK: Session
    //
    // Sign-out lives here rather than on the dashboard: this is the page that
    // shows what the card unlocks, so it is where a user looks when they want to
    // step away from it. The button is deliberately the last action on the page
    // and visually separated from everything above it, because it is the only
    // destructive control in the app.

    /// Shown verbatim in the confirmation dialog.
    static let signOutWarning = "退出后需要重新输入卡密才能使用。\n\n"
        + "本机的设备指纹（device_uuid）会保留，重新登录不会占用第二张卡密。"
        + "已下载的模型文件也不会被删除。"

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "会话", systemImage: "person.crop.circle.badge.xmark")

            SurfaceCard(padding: DS.Space.xs) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    confirmingSignOut = true
                } label: {
                    HStack(spacing: DS.Space.m) {
                        ZStack {
                            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                                .fill(Palette.dangerSoft)
                                .frame(width: 34, height: 34)
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Palette.danger)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("退出登录")
                                .font(DS.Font.body)
                                .fontWeight(.medium)
                                .foregroundColor(Palette.danger)
                            Text(signingOut ? "正在退出…" : "清除本机授权，返回卡密输入页")
                                .font(DS.Font.caption)
                                .foregroundColor(Palette.inkTertiary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)

                        // The teardown is fast but not instant: it stops a scan
                        // loop and frees a mapped model. Without this the row
                        // looks dead for that moment and gets tapped again.
                        if signingOut {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                    .padding(.vertical, DS.Space.s)
                    .padding(.horizontal, DS.Space.m)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(signingOut)
            }

            Text("退出只影响这台设备。卡密本身仍然绑定在此设备上，重新输入同一个卡密即可恢复。")
                .font(DS.Font.caption)
                .foregroundColor(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.xs)
        }
    }

    /// Runs the sign-out and gets out of the way.
    ///
    /// Split across two owners on purpose:
    ///
    ///   * the licence state itself is `LicenseManager`'s, and every write to it
    ///     has to go through one method — a value poked from a view is put back
    ///     by the next heartbeat;
    ///   * the switches this screen started (overlay scan loop, LLM) are torn
    ///     down here, because they are not licence state.
    ///
    /// The teardown is ordered outermost first: the overlay's scan loop feeds
    /// the shared inference engine, so the scan is stopped *before* the model is
    /// unloaded. The reverse order has a frame in flight against a freed
    /// context.
    ///
    /// `device_uuid` is deliberately untouched. It lives in the Keychain, not in
    /// `UserDefaults`, and it is the device fingerprint the card is bound to —
    /// clearing it would present this phone to the server as a new device and
    /// make signing back in consume a second card.
    @MainActor
    private func performSignOut() {
        guard !signingOut else { return }
        signingOut = true

        // `hideOverlay()` already stops the scan loop, the tap-through holes and
        // the component heartbeat poll, and tears the window down on the next
        // run-loop turn.
        OverlayState.shared.hideOverlay()

        Task { @MainActor in
            await LlamaModelManager.shared.unload()
            // Stops the heartbeat, drops `lic.hasGrant` / `lic.lastCard`, resets
            // the published profile and flips the state to `.notActivated`, which
            // is what sends RootView back to the card screen.
            license.signOut()
            Self.clearCachedProfile()
            signingOut = false
        }
    }

    /// Removes the cosmetic profile cache.
    ///
    /// These six keys are the whole persisted identity. `signOut()` above owns
    /// the first two; the rest are cleared here because they are display-only
    /// copies of what the server said, and a stale nickname or level must not
    /// greet the next person who activates on this device.
    ///
    /// This belongs inside `LicenseManager.logout()` once that method exists —
    /// see the hand-off notes in the report; it is kept here so the button works
    /// against the manager's current surface.
    private static func clearCachedProfile() {
        let d = UserDefaults.standard
        for key in ["lic.lastCard", "lic.hasGrant", "lic.nickname",
                    "lic.level", "lic.levelName", "lic.expiresAt"] {
            d.removeObject(forKey: key)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "关于", systemImage: "info.circle")

            SurfaceCard(padding: DS.Space.xs) {
                VStack(spacing: 0) {
                    ActionRow(title: "更新日志",
                              subtitle: "查看各版本改动",
                              systemImage: "doc.plaintext",
                              iconTint: Palette.accent,
                              iconBackground: Palette.accentSoft,
                              showsChevron: true) {
                        showChangelog = true
                    }
                    Hairline()
                    ActionRow(title: "作者",
                              subtitle: "\(AppBrand.author) · \(AppBrand.contact)",
                              systemImage: "person.crop.square",
                              iconTint: Palette.inkSecondary,
                              iconBackground: Palette.surfaceAlt,
                              showsChevron: false) {}
                }
            }
        }
        .sheet(isPresented: $showChangelog) {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {
                        ForEach(Changelog.entries, id: \.version) { entry in
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                HStack(spacing: DS.Space.s) {
                                    Text("v\(entry.version)")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(Palette.accent)
                                    Text(entry.date)
                                        .font(DS.Font.caption)
                                        .foregroundColor(Palette.inkTertiary)
                                }
                                ForEach(entry.items, id: \.self) { item in
                                    HStack(alignment: .top, spacing: 7) {
                                        Circle().fill(Palette.inkTertiary)
                                            .frame(width: 3, height: 3).padding(.top, 6)
                                        Text(item)
                                            .font(DS.Font.caption)
                                            .foregroundColor(Palette.inkSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: DS.Space.xl)
                    }
                    .padding(DS.Space.l)
                }
                .background(Palette.canvas)
                .navigationTitle("更新日志")
                .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
        }
    }

    @State private var showChangelog = false
    /// Set while the confirmation dialog is up.
    @State private var confirmingSignOut = false
    /// Blocks a second tap while the teardown is in flight.
    @State private var signingOut = false
}
