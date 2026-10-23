import SwiftUI

// MARK: - Card key login
//
// The single entry point into the app. There is no PIN: the card key is the
// credential, and it is checked against the server.
//
// Two stages share one screen:
//   1. card key   — always shown first
//   2. nickname   — revealed only when the server reports that this card has
//                   never been used, so a fresh user is asked how to address
//                   them. The card is not consumed until a name is supplied.

struct LoginView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var license = LicenseManager.shared

    @State private var cardCode = ""
    @State private var nickname = ""
    @FocusState private var focus: Field?

    private enum Field { case card, nickname }

    /// Set once the server asks for a display name.
    private var askingNickname: Bool {
        if case .needsNickname = license.state { return true }
        return false
    }

    private var nicknamePrompt: String {
        if case .needsNickname(let p, _, _) = license.state { return p }
        return "初次见面，请告诉我们怎么称呼您"
    }

    private var cardPreview: String {
        if case .needsNickname(_, let mask, let level) = license.state {
            return "\(level) · \(mask)"
        }
        return ""
    }

    private var blocked: Bool {
        switch license.state {
        case .killed, .banned: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.Space.xl) {
                    Spacer(minLength: DS.Space.xxl)

                    brand

                    if case .killed(let reason) = license.state {
                        blockedCard(icon: "xmark.octagon.fill", tint: Palette.danger,
                                    title: "此版本已停用", body: reason)
                    } else if case .banned(let reason) = license.state {
                        blockedCard(icon: "hand.raised.fill", tint: Palette.danger,
                                    title: "账号已被封禁",
                                    body: reason.isEmpty ? "请联系作者" : reason)
                    } else if askingNickname {
                        nicknameStage
                    } else {
                        cardStage
                    }

                    // Announcements are readable before activation, so a notice
                    // like "maintenance tonight" reaches users who cannot get in.
                    if !license.loginAnnouncements.isEmpty {
                        AnnouncementList(announcements: license.loginAnnouncements,
                                         compact: true)
                    }

                    Spacer(minLength: DS.Space.l)
                    CopyrightBanner()
                        .padding(.bottom, DS.Space.l)
                }
                .padding(.horizontal, DS.Space.l)
            }
        }
        .onAppear {
            focus = .card
            // Bootstrap runs once from RootView; doing it here as well would
            // fire two heartbeats on a cold start.
        }
        .onChangeCompat(of: license.state) { _, new in
            // Move the keyboard to the nickname field as soon as it appears.
            if case .needsNickname = new { focus = .nickname }
        }
    }

    // MARK: Brand

    private var brand: some View {
        VStack(spacing: DS.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Palette.accent)
                    .frame(width: 64, height: 64)
                    .shadow(color: Palette.accent.opacity(0.35), radius: 14, y: 6)
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.white)
            }
            VStack(spacing: 4) {
                Text(AppBrand.name)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(Palette.ink)
                Text(AppBrand.channel)
                    .font(DS.Font.callout)
                    .foregroundColor(Palette.inkTertiary)
            }
        }
    }

    // MARK: Stage 1 — card key

    private var cardStage: some View {
        SurfaceCard(padding: DS.Space.xl) {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("卡密验证")
                        .font(DS.Font.title)
                        .foregroundColor(Palette.ink)
                    Text("输入卡密以激活本设备。卡密与设备绑定，一次激活长期有效。")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextInputField(label: "卡密",
                               placeholder: "BETA-XXXX-XXXX-XXXX-XXXX",
                               text: $cardCode,
                               systemImage: "key.fill",
                               error: license.lastError)
                    .focused($focus, equals: .card)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                    .onChangeCompat(of: cardCode) { _, v in
                        // Normalise while typing: a rejection caused only by
                        // spacing or lowercase is a needless round trip.
                        let cleaned = v.uppercased()
                            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
                        if cleaned != v { cardCode = cleaned }
                        if license.lastError != nil { license.clearError() }
                    }

                PrimaryButton(title: license.verifying ? "验证中" : "验证并激活",
                              systemImage: "checkmark.seal.fill",
                              loading: license.verifying,
                              enabled: cardCode.count >= 8 && !license.verifying) {
                    focus = nil
                    Task { await license.activate(cardCode: cardCode) }
                }

                Hairline()

                deviceInfo
            }
        }
    }

    // MARK: Stage 2 — nickname

    private var nicknameStage: some View {
        SurfaceCard(padding: DS.Space.xl) {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(nicknamePrompt)
                        .font(DS.Font.title)
                        .foregroundColor(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !cardPreview.isEmpty {
                        Text(cardPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Palette.accent)
                    }
                }

                TextInputField(label: "称呼",
                               placeholder: "例如：小张",
                               text: $nickname,
                               systemImage: "person.fill",
                               error: license.lastError)
                    .focused($focus, equals: .nickname)
                    .onChangeCompat(of: nickname) { _, _ in
                        if nickname.count > 20 {
                            nickname = String(nickname.prefix(20))
                        }
                        if license.lastError != nil { license.clearError() }
                    }

                PrimaryButton(title: "完成激活",
                              systemImage: "checkmark.circle.fill",
                              loading: license.verifying,
                              enabled: !nickname.trimmingCharacters(in: .whitespaces).isEmpty
                                       && !license.verifying) {
                    focus = nil
                    // Reuse the stored code: the server has not consumed the
                    // card yet, so this is the same activation attempt.
                    let code = UserDefaults.standard.string(forKey: "lic.lastCard") ?? cardCode
                    Task { await license.activate(cardCode: code, nickname: nickname) }
                }

                Button {
                    // Back out without consuming anything.
                    nickname = ""
                    license.clearError()
                    Task { await license.reloadState() }
                } label: {
                    Text("重新输入卡密")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Device info

    private var deviceInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("设备号")
                .font(DS.Font.caption)
                .foregroundColor(Palette.inkTertiary)
            Text(license.deviceId)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("购买卡密时若需提供设备号，复制这一串。")
                .font(.system(size: 10))
                .foregroundColor(Palette.inkTertiary)
        }
    }

    private func blockedCard(icon: String, tint: Color,
                             title: String, body: String) -> some View {
        SurfaceCard(padding: DS.Space.xl) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(tint)
                    Text(title)
                        .font(DS.Font.title)
                        .foregroundColor(Palette.ink)
                }
                Text(body)
                    .font(DS.Font.body)
                    .foregroundColor(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Announcement list

struct AnnouncementList: View {
    let announcements: [Announcement]
    var compact: Bool = false

    @ObservedObject private var license = LicenseManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(announcements) { a in
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Image(systemName: a.type == "maintenance"
                          ? "wrench.and.screwdriver.fill" : "megaphone.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.accent)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(a.title)
                            .font(DS.Font.caption.weight(.semibold))
                            .foregroundColor(Palette.ink)
                        Text(a.content)
                            .font(.system(size: compact ? 10 : 11))
                            .foregroundColor(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)

                    if a.once {
                        Button {
                            Task { await license.ackAnnouncement(a.id) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Palette.inkTertiary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                        .fill(Palette.accentSoft.opacity(0.6))
                )
            }
        }
    }
}

// MARK: - Update prompts

/// Full-screen gate for a forced update.
///
/// Every pending line gets its own block: the App bundle and the auth component
/// are separate products, both can be behind at once, and the two sets of
/// instructions are not interchangeable.
struct ForcedUpdateView: View {
    let notices: [VersionNotice]

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.Space.xl) {
                    Spacer(minLength: DS.Space.xxl)

                    ZStack {
                        Circle().fill(Palette.warningSoft).frame(width: 80, height: 80)
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 38, weight: .medium))
                            .foregroundColor(Palette.warning)
                    }

                    VStack(spacing: DS.Space.s) {
                        Text("需要更新")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(Palette.ink)
                        Text("完成更新后才能继续使用。")
                            .font(DS.Font.body)
                            .foregroundColor(Palette.inkSecondary)
                    }

                    VStack(spacing: DS.Space.l) {
                        ForEach(notices) { notice in
                            UpdateNoticeCard(notice: notice)
                        }
                    }

                    Spacer(minLength: DS.Space.l)
                    CopyrightBanner()
                }
                .padding(DS.Space.l)
            }
        }
    }
}

/// Closable banner for an advisory update: same information, no gate.
struct UpdateNoticeBanner: View {
    let notice: VersionNotice
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .fill(Palette.accentSoft)
                        .frame(width: 32, height: 32)
                    Image(systemName: notice.isDylib ? "shippingbox.fill" : "arrow.down.app.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Palette.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(DS.Font.headline)
                        .foregroundColor(Palette.ink)
                    Text("v\(notice.latest) · 可以稍后再更新")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                }

                Spacer(minLength: 0)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Palette.inkTertiary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !notice.changelog.isEmpty {
                UpdateNoteList(lines: notice.changelog)
            }

            HStack(spacing: DS.Space.s) {
                if let dest = notice.destination {
                    Link(destination: dest) {
                        HStack(spacing: 6) {
                            Image(systemName: "safari.fill")
                            Text("官网换取下载链接")
                        }
                        .font(DS.Font.caption.weight(.semibold))
                        .foregroundColor(Palette.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Palette.accentSoft))
                    }
                }

                Text(notice.isDylib
                     ? "下载新驱动后注入到最新版 IPA 包内"
                     : "下载最新版 IPA 安装包")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .stroke(Palette.separator, lineWidth: 1)
        )
        .shadow(color: Palette.shadowStrong, radius: 16, y: 6)
    }
}

/// Full detail block: what changed, then the two steps that get the user there.
struct UpdateNoticeCard: View {
    let notice: VersionNotice

    var body: some View {
        SurfaceCard(padding: DS.Space.l, elevated: true) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: notice.isDylib ? "shippingbox.fill" : "arrow.down.app.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Palette.accent)

                    Text(notice.title)
                        .font(DS.Font.headline)
                        .foregroundColor(Palette.ink)

                    Spacer(minLength: 0)

                    Text("v\(notice.latest)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.accentSoft))
                }

                Text(notice.headline)
                    .font(DS.Font.body)
                    .foregroundColor(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !notice.changelog.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("本次更新内容")
                            .font(DS.Font.caption.weight(.semibold))
                            .foregroundColor(Palette.inkTertiary)
                            .letterSpacing(0.6)
                        UpdateNoteList(lines: notice.changelog)
                    }
                }

                Hairline()

                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(Array(notice.steps.enumerated()), id: \.offset) { idx, step in
                        HStack(alignment: .top, spacing: DS.Space.s) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Palette.accent))

                            Text(step)
                                .font(DS.Font.caption)
                                .foregroundColor(Palette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                }

                if let dest = notice.destination {
                    Link(destination: dest) {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "safari.fill")
                            Text("打开官网换取下载链接")
                        }
                        .font(DS.Font.body.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Palette.accent))
                    }
                }
            }
        }
    }
}

/// Bulleted release notes, shared by the gate and the banner.
struct UpdateNoteList: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 3, height: 3)
                        .padding(.top, 5)
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
