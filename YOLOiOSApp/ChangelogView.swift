import SwiftUI

// MARK: - Changelog
//
// Shown on the login screen so every install makes its changes obvious without
// needing a separate release-notes page.

struct ChangelogEntry: Identifiable, Hashable {
    let version: String
    let date: String
    let items: [String]

    var id: String { version + date }
}

enum Changelog {
    /// Newest first. The login screen shows the top entry; the rest are
    /// reachable by expanding.
    ///
    /// Written for users, not for the team: every line says what they can now do
    /// or which annoyance is gone. No component names, no internal vocabulary —
    /// a user reading this must never have to decode a word.
    ///
    /// The running build's own version is NOT hardcoded here — `currentEntry`
    /// matches the ship version from the bundle, so the header can never claim a
    /// version older than the app itself.
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(version: "2.6.0", date: "内测版", items: [
            "登录方式改为卡密，不用再记 PIN 码",
            "新卡密第一次激活会问你怎么称呼，以后每次进 App 都会用这个名字",
            "修复卡密只激活一次就被提示「已被使用」的问题",
            "新增「我的」页面：等级、能用哪些功能、到期时间、设备号，一页看完",
            "新增权限系统：不同卡密能用的功能一目了然，锁住的功能会说明原因",
            "新增公告：卡密页和主界面都能第一时间看到官方通知",
        ]),
        ChangelogEntry(version: "2.5.0", date: "内测版", items: [
            "修复悬浮窗点不动的问题（启动方式面板没有响应区域）",
            "修复底部标签栏看不出选中了哪一项、滑块位置错乱",
            "摄像头不再被限制在 16 帧，画面更顺畅",
            "接入卡密服务：卡密可以直接在 App 里验证激活",
            "新增安全校验，保护你的卡密不被别人盗用",
        ]),
        ChangelogEntry(version: "2.4.0", date: "内测版", items: [
            "修复选了巨魔模式之后悬浮窗完全没法操作的问题",
            "修复摄像头帧率被锁死、画面卡顿的问题",
            "修复识别框偶尔擦不掉、残留在画面上的问题",
        ]),
        ChangelogEntry(version: "2.3.0", date: "内测版", items: [
            "底部标签栏改成悬浮的液态玻璃胶囊，更好看也更好按",
            "悬浮窗面板换成玻璃质感，支持左右滑动切换页签",
        ]),
        ChangelogEntry(version: "2.2.0", date: "内测版", items: [
            "新增启动方式选择（巨魔 / 自签），按你的环境挑一个",
            "新增内核层初始化，启动时会先检查环境是否支持",
            "自瞄辅助按启动方式分级开放",
        ]),
        ChangelogEntry(version: "2.1.0", date: "内测版", items: [
            "修复 AI 对话有时停不下来、反复重复同一句话的问题",
            "修复 AI 的回复重复显示两遍的问题",
            "修复让 AI 保存文件时存出来是空文件的问题",
            "修复「从内存卸载」按钮点了没反应的问题",
            "照片识别：识别前调好的参数现在真的生效了",
            "登录页新增更新日志，每次更新都能看到改了什么",
        ]),
        ChangelogEntry(version: "2.0.0", date: "内测版", items: [
            "AI 对话改为一个字一个字显示，回答不用等全部生成完",
            "修复模型卸载后状态显示不对的问题",
        ]),
        ChangelogEntry(version: "1.9.0", date: "内测版", items: [
            "界面改用 iOS 26 的液态玻璃效果",
            "照片识别：可以边调参数边预览，识别后的标注图能直接存进相册",
            "登录页重新设计，看起来更清爽",
        ]),
        ChangelogEntry(version: "1.8.0", date: "内测版", items: [
            "修复偶尔误进安全模式、启动后打不开界面的问题",
            "聊天记录会保存下来，退出 App 再进来还在",
            "AI 对话可以自定义说话风格和背景信息，也可以随时关掉",
            "导入模型后可以直接使用，不用再做额外设置",
            "新增沙盒工具：可以让 AI 读写文件，每次操作前都会先问你",
            "模型下载支持断点续传，网断了不用从头再下",
        ]),
    ]

    /// The entry matching the running build, or the newest one.
    static var currentEntry: ChangelogEntry {
        let running = AppBrand.shortVersion
        return entries.first { $0.version == running } ?? entries.first!
    }
}

/// Compact, expandable changelog for the login screen.
struct ChangelogView: View {
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button {
                withAnimation(DS.Motion.standard) { expanded.toggle() }
            } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Palette.inkTertiary)
                    Text("更新日志")
                        .font(DS.Font.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(Palette.inkSecondary)
                    Text("v\(Changelog.currentEntry.version)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Palette.accent)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Palette.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(Array(Changelog.entries.enumerated()), id: \.offset) { idx, entry in
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            HStack(spacing: DS.Space.s) {
                                Text("v\(entry.version)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(idx == 0 ? Palette.accent : Palette.inkSecondary)
                                Text(entry.date)
                                    .font(.system(size: 10))
                                    .foregroundColor(Palette.inkTertiary)
                            }
                            ForEach(entry.items, id: \.self) { item in
                                HStack(alignment: .top, spacing: 6) {
                                    Circle()
                                        .fill(idx == 0 ? Palette.accent : Palette.inkTertiary)
                                        .frame(width: 3, height: 3)
                                        .padding(.top, 5)
                                    Text(item)
                                        .font(.system(size: 11))
                                        .foregroundColor(Palette.inkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if idx < Changelog.entries.count - 1 {
                            Hairline()
                        }
                    }
                }
                .padding(DS.Space.m)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                        .fill(Palette.surfaceAlt)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
