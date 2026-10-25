import SwiftUI
import PhotosUI

// MARK: - Chat tab
//
// Uses the same design system as the rest of the app (white surfaces, hairline
// borders, one accent) so the new tab reads as part of the product rather than
// a bolted-on module.

struct ChatView: View {
    @StateObject private var vm = ChatViewModel()
    @ObservedObject private var manager = LlamaModelManager.shared
    @ObservedObject private var store = DetectionStore.shared
    @ObservedObject private var ai = AIContextSettings.shared
    @EnvironmentObject private var app: AppState

    @State private var showModelSheet = false
    @State private var showAISettings = false
    @State private var showHistory = false
    @State private var showContext = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                modelBar
                Divider().overlay(Palette.separator)

                // Explains a locked feature at the top of the screen rather than
                // leaving the send button inert with no reason given.
                if vm.gateMessage != nil {
                    FeatureLockedBanner(feature: "chat_basic")
                        .padding(.horizontal, DS.Space.l)
                        .padding(.top, DS.Space.s)
                }

                if vm.messages.isEmpty {
                    emptyState
                } else {
                    messageList
                }

                if showContext { contextPanel }

                if let cmd = vm.pendingCommand {
                    toolConfirmBar(cmd)
                }

                composer
            }
        }
        .sheet(isPresented: $showModelSheet) {
            LlamaModelSheet()
        }
        .sheet(isPresented: $showAISettings) {
            AISettingsView()
        }
        .sheet(isPresented: $showHistory) {
            ChatHistorySheet(vm: vm)
        }
        .onAppear {
            vm.activateCurrentConversation()
        }
    }

    // MARK: Tool confirmation

    private func toolConfirmBar(_ cmd: SandboxTools.ProposedCommand) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.warning)
                Text("模型想执行一个操作")
                    .font(DS.Font.callout)
                    .fontWeight(.semibold)
                    .foregroundColor(Palette.ink)
                Spacer(minLength: 0)
            }

            Text(cmd.command + "  " + cmd.displayArgument)
                .font(DS.Font.mono)
                .foregroundColor(Palette.inkSecondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.Space.s) {
                SecondaryButton(title: "拒绝", systemImage: "xmark", role: .destructive) {
                    vm.rejectPendingCommand()
                }
                PrimaryButton(title: "执行", systemImage: "checkmark") {
                    vm.confirmPendingCommand()
                }
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warningSoft)
        .overlay(alignment: .top) { Divider().overlay(Palette.separator) }
    }

    // MARK: Model bar

    private var modelBar: some View {
        VStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
            Button {
                showModelSheet = true
            } label: {
                HStack(spacing: DS.Space.s) {
                    StatusChip(level: chipLevel, text: manager.tier.title)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(manager.spec.displayName)
                            .font(DS.Font.callout)
                            .fontWeight(.semibold)
                            .foregroundColor(Palette.ink)
                            .lineLimit(1)
                        Text(manager.statusLine.isEmpty ? manager.state.label : manager.statusLine)
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.inkTertiary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Palette.inkTertiary)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            if manager.state == .downloading {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: manager.downloadProgress)
                        .frame(width: 60)
                        .tint(Palette.accent)
                    Text(manager.downloadSpeedText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Palette.inkTertiary)
                }
            }

            Button {
                withAnimation(DS.Motion.standard) { showContext.toggle() }
            } label: {
                Image(systemName: "eye\(showContext ? ".fill" : "")")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(showContext ? Palette.accent : Palette.inkSecondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Palette.surfaceAlt))
            }
            .buttonStyle(.plain)

            Button {
                showAISettings = true
            } label: {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ai.injectDetection ? Palette.accent : Palette.inkSecondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Palette.surfaceAlt))
            }
            .buttonStyle(.plain)

            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Palette.inkSecondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Palette.surfaceAlt))
            }
            .buttonStyle(.plain)

            Button {
                vm.startNewConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Palette.inkSecondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Palette.surfaceAlt))
            }
            .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
            .background(Palette.surface)

            // Credit line, always visible in the chat tab.
            CopyrightBadge(compact: true)
                .padding(.horizontal, DS.Space.l)
                .padding(.bottom, DS.Space.s)
                .background(Palette.surface)
        }
    }

    private var chipLevel: StatusChip.Level {
        switch manager.state {
        case .ready: return .ready
        case .absent, .paused: return .idle
        case .failed: return .error
        case .loading, .downloading: return .busy
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: DS.Space.l) {
                Spacer(minLength: DS.Space.xxl)

                SurfaceCard(padding: DS.Space.xl) {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(Palette.accent)
                            Text("本地离线对话")
                                .font(DS.Font.title)
                                .foregroundColor(Palette.ink)
                        }
                        Text("模型完全跑在这台设备上，不联网、不上传。聊天时会自动带上摄像头检测到的内容。")
                            .font(DS.Font.callout)
                            .foregroundColor(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, DS.Space.l)

                if !manager.spec.isDownloaded {
                    SurfaceCard(padding: DS.Space.l) {
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            Text("先准备一个模型")
                                .font(DS.Font.headline)
                                .foregroundColor(Palette.ink)
                            Text("\(manager.spec.displayName) · \(manager.spec.sizeText)，点上方状态条选择档位或下载。")
                                .font(DS.Font.caption)
                                .foregroundColor(Palette.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            PrimaryButton(title: "选择 / 下载模型",
                                          systemImage: "arrow.down.circle") {
                                showModelSheet = true
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.l)
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        SectionHeader(title: "试着问", systemImage: "lightbulb")
                        ForEach(suggestions, id: \.self) { s in
                            Button {
                                vm.input = s
                                inputFocused = true
                            } label: {
                                HStack {
                                    Text(s)
                                        .font(DS.Font.callout)
                                        .foregroundColor(Palette.ink)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.left")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Palette.inkTertiary)
                                }
                                .padding(.horizontal, DS.Space.m)
                                .padding(.vertical, DS.Space.m)
                                .background(
                                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                                        .fill(Palette.surface)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                                        .stroke(Palette.separator, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DS.Space.l)
                }

                Spacer(minLength: DS.Space.xl)
            }
        }
    }

    private var suggestions: [String] {
        ["刚才有几个人？", "描述一下现在画面", "有人靠近吗？", "最后一次看到人是什么时候？"]
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: DS.Space.m) {
                    ForEach(vm.messages) { m in
                        if m.role == .system {
                            SystemNoteRow(text: m.text)
                                .id(m.id)
                        } else {
                            MessageBubble(message: m)
                                .id(m.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)
            }
            .onChangeCompat(of: vm.messages.count) { _, _ in
                withAnimation(DS.Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChangeCompat(of: vm.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: Context panel

    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.accent)
                Text("将随提问发送的检测上下文")
                    .font(DS.Font.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(Palette.inkSecondary)
                Spacer(minLength: 0)
            }
            Text(store.contextBlock())
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.accentSoft)
        .overlay(alignment: .top) { Divider().overlay(Palette.separator) }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Palette.separator)

            HStack(alignment: .bottom, spacing: DS.Space.s) {
                composerField

                if vm.isGenerating {
                    Button {
                        vm.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                                    .fill(Palette.danger)
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        vm.send()
                        inputFocused = false
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                                    .fill(canSend ? Palette.accent : Palette.inkTertiary.opacity(0.4))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)

            // Stats line
            if vm.isGenerating || vm.tokensPerSecond > 0 {
                HStack(spacing: DS.Space.s) {
                    if vm.isGenerating {
                        ProgressView().scaleEffect(0.6)
                    }
                    Text(vm.isGenerating ? "生成中" : "上次")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                    if vm.tokensPerSecond > 0 {
                        Text(String(format: "%.1f tok/s", vm.tokensPerSecond))
                            .font(DS.Font.mono)
                            .foregroundColor(Palette.accent)
                    }
                    Text("·").foregroundColor(Palette.inkTertiary)
                    Text(manager.spec.displayName)
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.bottom, DS.Space.s)
            }
        }
        .background(Palette.surface)
        // Clear the floating tab bar so the composer is never covered.
        .padding(.bottom, MainTabView.barFootprint - 44)
    }

    /// Composer input.
    ///
    /// iOS 16 has a `TextField` that grows with its content; iOS 15 has no such
    /// thing, so the fallback is a fixed one-line-tall `PlainTextEditor` that
    /// scrolls internally — same footprint as the collapsed iOS 16 field, so the
    /// composer row is the same height on every system.
    @ViewBuilder
    private var composerField: some View {
        Group {
            if #available(iOS 16.0, *) {
                TextField("问点什么…", text: $vm.input, axis: .vertical)
                    .font(DS.Font.body)
                    .foregroundColor(Palette.ink)
                    .lineLimit(1...5)
                    .focused($inputFocused)
            } else {
                ZStack(alignment: .topLeading) {
                    if vm.input.isEmpty {
                        Text("问点什么…")
                            .font(DS.Font.body)
                            .foregroundColor(Palette.inkTertiary)
                            .allowsHitTesting(false)
                    }
                    PlainTextEditor(text: $vm.input)
                        .frame(height: 22)
                }
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(Palette.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        )
    }

    private var canSend: Bool {
        !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !vm.isGenerating
    }
}

// MARK: - System note
// Tool results and errors, rendered as a centred card rather than a bubble so
// they read as system events rather than something either side said.

struct SystemNoteRow: View {
    let text: String

    private var isError: Bool { text.hasPrefix("⚠️") }
    private var isTool: Bool { text.hasPrefix("🛠") }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: isError ? "exclamationmark.triangle.fill"
                                          : (isTool ? "wrench.and.screwdriver.fill" : "info.circle.fill"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isError ? Palette.danger : Palette.inkTertiary)
                Text(text)
                    .font(DS.Font.caption)
                    .foregroundColor(isError ? Palette.danger : Palette.inkSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(isError ? Palette.dangerSoft : Palette.surfaceAlt)
            )
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Message bubble

struct MessageBubble: View {
    let message: ChatMessage
    @State private var showReasoning = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading,
                   spacing: DS.Space.xs) {

                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup(isExpanded: $showReasoning) {
                        Text(reasoning)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Palette.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "brain")
                                .font(.system(size: 10, weight: .semibold))
                            Text(showReasoning ? "收起思考过程" : "模型思考过程")
                                .font(DS.Font.caption)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(Palette.inkTertiary)
                    }
                    .tint(Palette.inkTertiary)
                }

                if !message.text.isEmpty {
                    Text(message.text)
                        .font(DS.Font.body)
                        .foregroundColor(message.role == .user ? .white : Palette.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, DS.Space.m)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                                .fill(message.role == .user ? Palette.accent : Palette.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                                .stroke(message.role == .user ? Color.clear : Palette.separator,
                                        lineWidth: 1)
                        )
                }

                if message.isStreaming && message.text.isEmpty {
                    HStack(spacing: 5) {
                        ProgressView().scaleEffect(0.6)
                        Text(message.reasoning == nil ? "思考中…" : "整理回答…")
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.inkTertiary)
                    }
                }

                if let error = message.error {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(error).font(DS.Font.caption)
                    }
                    .foregroundColor(Palette.danger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(Palette.dangerSoft)
                    )
                }

                if message.role == .assistant, !message.isStreaming, message.tokens > 0 {
                    Text(String(format: "%d tokens · %.1fs · %.1f tok/s",
                                message.tokens,
                                message.durationSeconds,
                                message.durationSeconds > 0
                                    ? Double(message.tokens) / message.durationSeconds : 0))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Palette.inkTertiary)
                }
            }

            if message.role != .user { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}
