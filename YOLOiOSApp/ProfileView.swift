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
                aboutSection
                CopyrightBanner()
                Color.clear.frame(height: MainTabView.barFootprint)
            }
            .padding(DS.Space.l)
        }
        .background(Palette.canvas)
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
}
