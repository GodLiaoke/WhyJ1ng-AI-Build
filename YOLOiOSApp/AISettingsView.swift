import SwiftUI

// MARK: - AI settings sheet
//
// Controls what the model is told and what it is allowed to do. Exposed because
// a small local model degrades fast when the context is wrong, and because the
// user should be able to see — and veto — every capability.

struct AISettingsView: View {
    @ObservedObject private var ai = AIContextSettings.shared
    @ObservedObject private var store = DetectionStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showRawPrompt = false

    var body: some View {
        NavigationView {
            ZStack {
                Palette.canvas.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {

                        systemPromptSection
                        contextSection
                        toolsSection
                        previewSection
                        resetSection

                        CopyrightBadge()
                        Color.clear.frame(height: DS.Space.xl)
                    }
                    .padding(DS.Space.l)
                }
            }
            .navigationTitle("AI 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: System prompt

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "系统提示词", systemImage: "text.bubble")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Text("这是每次提问前发给模型的身份说明。写得越简单直接，小模型表现越稳。")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    systemPromptField

                    HStack(spacing: DS.Space.s) {
                        Text("\(ai.systemPrompt.count) 字")
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.inkTertiary)
                        Spacer(minLength: 0)
                        Button("恢复默认") {
                            ai.systemPrompt = AIContextSettings.defaultSystemPrompt
                        }
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.accent)
                    }

                    Hairline()

                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("回答长度")
                            .font(DS.Font.callout)
                            .fontWeight(.medium)
                            .foregroundColor(Palette.ink)
                        HStack(spacing: DS.Space.s) {
                            ForEach(AIContextSettings.AnswerStyle.allCases) { style in
                                Chip(text: style.title, selected: ai.answerStyle == style) {
                                    ai.answerStyle = style
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: System prompt field

    /// Growing multiline field: iOS 16 has `TextField(axis:)`, iOS 15 does not.
    ///
    /// The fallback is a fixed-height `PlainTextEditor` rather than a deleted
    /// control, so a prompt of any length can still be written and edited on 15.
    /// Both branches share the same chrome, so the section is indistinguishable
    /// apart from the field growing by itself on newer systems.
    @ViewBuilder
    private var systemPromptField: some View {
        Group {
            if #available(iOS 16.0, *) {
                TextField("系统提示词", text: $ai.systemPrompt, axis: .vertical)
                    .font(DS.Font.callout)
                    .foregroundColor(Palette.ink)
                    .lineLimit(4...14)
            } else {
                // A bare UITextView has no placeholder, so it is drawn behind it
                // in the same top-leading position the caret starts at.
                ZStack(alignment: .topLeading) {
                    if ai.systemPrompt.isEmpty {
                        Text("系统提示词")
                            .font(DS.Font.callout)
                            .foregroundColor(Palette.inkTertiary)
                            .allowsHitTesting(false)
                    }
                    PlainTextEditor(text: $ai.systemPrompt)
                        .frame(height: 132)
                }
            }
        }
        .padding(DS.Space.m)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(Palette.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        )
    }

    // MARK: Context

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "检测上下文注入", systemImage: "scope")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    ToggleRow(title: "注入检测数据",
                              subtitle: "关闭后模型完全不知道摄像头看到了什么，适合普通闲聊。信息越少，小模型越不容易胡言乱语。",
                              isOn: $ai.injectDetection)

                    if ai.injectDetection {
                        Hairline()

                        VStack(spacing: DS.Space.m) {
                            ToggleRow(title: "人数统计", isOn: $ai.includeCounts)
                            ToggleRow(title: "时间段", isOn: $ai.includeTrend)
                            ToggleRow(title: "识别类别", isOn: $ai.includeLabels)
                            ToggleRow(title: "最后出现时间", isOn: $ai.includeLastSeen)
                            ToggleRow(title: "靠近趋势", isOn: $ai.includeProximity)
                        }

                        Hairline()

                        SliderRow(title: "统计时间窗口",
                                  subtitle: "汇总最近多少秒的检测记录。",
                                  value: $ai.windowSeconds,
                                  range: 5...300,
                                  step: 5,
                                  valueText: "\(Int(ai.windowSeconds)) 秒")
                    }
                }
            }
        }
    }

    // MARK: Tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "沙盒工具", systemImage: "wrench.and.screwdriver")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    ToggleRow(title: "允许模型调用工具",
                              subtitle: "开启后模型可以读写沙盒内的文件（Documents/Sandbox）。它无法访问相册、相机、麦克风或沙盒外的任何位置。",
                              isOn: $ai.allowFileTools)

                    if ai.allowFileTools {
                        Hairline()

                        ToggleRow(title: "危险操作需要确认",
                                  subtitle: "删除、覆盖这类操作会先弹确认。建议保持开启。",
                                  isOn: $ai.toolsRequireConfirmation)

                        Hairline()

                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Text("可用命令")
                                .font(DS.Font.callout)
                                .fontWeight(.medium)
                                .foregroundColor(Palette.ink)
                            ForEach(SandboxTools.all) { tool in
                                HStack(spacing: DS.Space.s) {
                                    Text(tool.command)
                                        .font(DS.Font.mono)
                                        .foregroundColor(tool.destructive ? Palette.danger : Palette.accent)
                                    Text(tool.summary)
                                        .font(DS.Font.caption)
                                        .foregroundColor(Palette.inkSecondary)
                                    Spacer(minLength: 0)
                                    if tool.destructive {
                                        Text("需确认")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(Palette.danger)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Capsule().fill(Palette.dangerSoft))
                                    }
                                }
                            }
                        }

                        Hairline()

                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Text("沙盒目录")
                                .font(DS.Font.callout)
                                .fontWeight(.medium)
                                .foregroundColor(Palette.ink)
                            Text("「文件」App → 我的 iPhone → \(AppBrand.filesFolder) → Sandbox")
                                .font(DS.Font.caption)
                                .foregroundColor(Palette.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(SandboxTools.sandboxRoot.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Palette.inkTertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "将发送的内容", systemImage: "eye")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack {
                        Text("估算 \(ai.estimatedTokens) tokens")
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.inkTertiary)
                        Spacer(minLength: 0)
                        Button(showRawPrompt ? "收起" : "展开") {
                            withAnimation(DS.Motion.standard) { showRawPrompt.toggle() }
                        }
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.accent)
                    }

                    if showRawPrompt {
                        ScrollView {
                            Text(detectionPreviewText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Palette.inkSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 220)
                        .padding(DS.Space.s)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                                .fill(Palette.surfaceAlt)
                        )
                    } else {
                        Text(ai.injectDetection
                             ? "检测上下文已开启，将随每次提问发送。"
                             : "检测上下文已关闭，模型只会收到系统提示词。")
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.inkTertiary)
                    }
                }
            }
        }
    }

    private var detectionPreviewText: String {
        var parts: [String] = []
        parts.append("【系统提示词】")
        parts.append(ai.systemPrompt)
        parts.append("\n【长度要求】")
        parts.append(ai.answerStyle.instruction)
        let ctx = store.contextBlock(settings: ai)
        parts.append("\n【检测上下文】")
        parts.append(ctx.isEmpty ? "(未注入)" : ctx)
        if ai.allowFileTools {
            parts.append("\n【工具说明】")
            parts.append(SandboxTools.toolPrompt())
        }
        return parts.joined(separator: "\n")
    }

    private var resetSection: some View {
        SurfaceCard(padding: DS.Space.xs) {
            ActionRow(title: "恢复默认设置",
                      subtitle: "提示词 / 注入项 / 工具权限全部复位",
                      systemImage: "arrow.counterclockwise",
                      iconTint: Palette.warning,
                      iconBackground: Palette.warningSoft,
                      showsChevron: false) {
                ai.reset()
            }
        }
    }
}
