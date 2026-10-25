import Foundation
import Combine
import SwiftUI

// MARK: - Chat message

struct ChatMessage: Identifiable, Hashable {
    enum Role: String, Codable { case user, assistant, system }
    let id = UUID()
    var role: Role
    var text: String
    /// Reasoning block emitted by R1-style models, shown collapsed.
    var reasoning: String? = nil
    var isStreaming: Bool = false
    var tokens: Int = 0
    var durationSeconds: Double = 0
    var error: String? = nil
    var timestamp: Date = Date()

    var stored: StoredMessage {
        StoredMessage(role: role.rawValue,
                      text: text,
                      reasoning: reasoning,
                      timestamp: timestamp,
                      tokens: tokens,
                      durationSeconds: durationSeconds)
    }

    init(role: Role, text: String) {
        self.role = role
        self.text = text
    }

    init(stored: StoredMessage) {
        self.role = Role(rawValue: stored.role) ?? .assistant
        self.text = stored.text
        self.reasoning = stored.reasoning
        self.timestamp = stored.timestamp
        self.tokens = stored.tokens
        self.durationSeconds = stored.durationSeconds
    }
}

// MARK: - Chat view model

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    /// Set when a send is refused because the feature is not unlocked.
    @Published var gateMessage: String? = nil
    @Published var isGenerating = false
    @Published private(set) var tokensPerSecond: Double = 0
    @Published private(set) var lastPromptChars: Int = 0

    /// A tool call the model proposed, awaiting the user's decision.
    @Published var pendingCommand: SandboxTools.ProposedCommand? = nil
    /// Result of the last executed tool, shown in the transcript.
    @Published var lastToolResult: String? = nil

    private var generationTask: Task<Void, Never>? = nil
    private let store = DetectionStore.shared
    private let manager = LlamaModelManager.shared
    private let history = ChatHistoryStore.shared
    private let aiSettings = AIContextSettings.shared

    /// Id of the conversation currently being appended to.
    private var conversationID: UUID?

    // Sampling defaults.
    var temperature: Float = 0.7
    var topP: Float = 0.9
    var repeatPenalty: Float = 1.1
    var maxTokens: Int = 512

    // MARK: Conversation lifecycle

    /// Loads whichever conversation should be active, creating one if needed.
    func activateCurrentConversation() {
        if let current = history.current {
            conversationID = current.id
            messages = current.messages.map(ChatMessage.init(stored:))
        } else if let first = history.conversations.first {
            history.select(first.id)
            conversationID = first.id
            messages = first.messages.map(ChatMessage.init(stored:))
        } else {
            startNewConversation()
        }
    }

    func startNewConversation() {
        stop()
        let id = history.startNew(modelName: manager.spec.displayName)
        conversationID = id
        messages = []
        tokensPerSecond = 0
    }

    func openConversation(_ id: UUID) {
        stop()
        history.select(id)
        conversationID = id
        if let conv = history.current {
            messages = conv.messages.map(ChatMessage.init(stored:))
        } else {
            messages = []
        }
    }

    func deleteConversation(_ id: UUID) {
        if id == conversationID {
            messages = []
            conversationID = nil
        }
        history.delete(id)
        activateCurrentConversation()
    }

    var conversations: [ChatConversation] { history.conversations }

    /// Ensures some model is loaded, preferring an imported one when active.
    private func ensureAnyModelLoaded() async -> Bool {
        let custom = CustomModelStore.shared
        if custom.isActive {
            if await LlamaEngine.shared.isLoaded,
               await LlamaEngine.shared.loadedPath == custom.activeURL?.path {
                return true
            }
            guard let url = custom.activeURL else { return false }
            await custom.activate(url)
            return await LlamaEngine.shared.isLoaded
        }
        return await manager.ensureLoaded()
    }

    // MARK: Sending

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }

        // Gate checked per send, not once at launch: a level change takes effect
        // on the next message rather than the next cold start.
        guard FeatureGateCheck.allow("chat_basic") else {
            gateMessage = LicenseManager.shared.gateReason("chat_basic")
            return
        }
        gateMessage = nil

        input = ""

        // A conversation must exist before the first message is persisted.
        if conversationID == nil { startNewConversation() }
        guard let convID = conversationID else { return }

        let userMessage = ChatMessage(role: .user, text: text)
        messages.append(userMessage)
        history.append(userMessage.stored, to: convID)

        var assistant = ChatMessage(role: .assistant, text: "")
        assistant.isStreaming = true
        messages.append(assistant)
        let assistantID = assistant.id

        isGenerating = true
        let started = Date()

        generationTask = Task { [weak self] in
            guard let self else { return }

            let ok = await self.ensureAnyModelLoaded()
            guard ok else {
                self.fail(assistantID, "模型未就绪，请先下载或导入模型")
                return
            }

            // Questions that can be answered from data alone skip the model
            // entirely, which is both faster and more accurate.
            let direct = self.aiSettings.injectDetection
                ? DetectionIntent.classify(text, store: self.store).1
                : nil

            let prompt = await self.buildPrompt(userText: text)
            self.lastPromptChars = prompt.count

            let stream = await LlamaEngine.shared.generate(
                prompt: prompt,
                temperature: self.temperature,
                topP: self.topP,
                repeatPenalty: self.repeatPenalty,
                maxTokens: self.maxTokens
            )

            var emitted = 0
            var accumulated = ""
            var reasoning = ""
            /// Whether the engine has handed over the authoritative final text.
            var sawFinal = false

            do {
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    emitted = chunk.tokens

                    if chunk.isFinal {
                        // Authoritative: replace rather than append, because a
                        // stop-sequence cut can shorten the tail.
                        accumulated = chunk.text
                        sawFinal = true
                    } else {
                        accumulated += chunk.text
                    }

                    let (clean, rea) = Self.splitReasoning(accumulated)
                    if !rea.isEmpty { reasoning = rea }
                    self.setAssistant(assistantID, text: clean, reasoning: reasoning)
                }
            } catch LlamaEngineError.cancelled {
                // User pressed stop; keep whatever was produced.
            } catch {
                self.fail(assistantID, error.localizedDescription)
                return
            }

            // If the model produced nothing but the data has an answer, use it.
            if emitted == 0, let direct {
                accumulated = direct
                self.setAssistant(assistantID, text: direct, reasoning: "")
            }
            _ = sawFinal

            let elapsed = Date().timeIntervalSince(started)
            self.finish(assistantID, tokens: emitted, duration: elapsed,
                        tps: elapsed > 0 ? Double(emitted) / elapsed : 0)
            self.persistTurn(assistantID, convID: convID,
                             text: accumulated, reasoning: reasoning,
                             tokens: emitted, duration: elapsed)

            // Look for a tool call in the finished reply. Parsing happens after
            // the stream ends so a half-written block is never executed.
            if self.aiSettings.allowFileTools {
                let commands = SandboxTools.parseCommands(in: accumulated)
                if let first = commands.first {
                    self.handleProposedCommand(first)
                }
            }
        }
    }

    func stop() {
        generationTask?.cancel()
        generationTask = nil
        Task { await LlamaEngine.shared.cancel() }
        if let idx = messages.lastIndex(where: { $0.isStreaming }) {
            messages[idx].isStreaming = false
        }
        isGenerating = false
    }

    /// Clears the current conversation's messages but keeps it in the list.
    func clearCurrent() {
        stop()
        guard let convID = conversationID else { return }
        messages.removeAll()
        history.delete(convID)
        startNewConversation()
    }

    func retryLast() {
        guard let lastUser = messages.last(where: { $0.role == .user }) else { return }
        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
            messages.remove(at: idx)
        }
        let text = lastUser.text
        messages.removeAll { $0.role == .user && $0.id == lastUser.id }
        input = text
        send()
    }

    // MARK: Prompt construction

    /// System prompt + rolling history + the detection context block.
    private func buildPrompt(userText: String) async -> String {
        var system = aiSettings.systemPrompt
        system += "\n" + aiSettings.answerStyle.instruction

        let context = store.contextBlock(settings: aiSettings)
        if !context.isEmpty {
            system += "\n\n" + context
        }

        if aiSettings.allowFileTools {
            system += "\n\n" + SandboxTools.toolPrompt()
        }

        var msgs: [(role: String, content: String)] = [("system", system)]

        // Keep the last few turns; local context windows are small.
        let history = messages
            .filter { $0.role != .system && !$0.text.isEmpty }
            .suffix(6)
        for m in history {
            msgs.append((m.role == .user ? "user" : "assistant", m.text))
        }
        if !history.contains(where: { $0.role == .user && $0.text == userText }) {
            msgs.append(("user", userText))
        }

        return await LlamaEngine.shared.chatPrompt(messages: msgs, addAssistant: true)
    }

    // MARK: Message mutation

    private func setAssistant(_ id: UUID, text: String, reasoning: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text = text
        if !reasoning.isEmpty { messages[idx].reasoning = reasoning }
    }

    private func finish(_ id: UUID, tokens: Int, duration: Double, tps: Double) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].isStreaming = false
            messages[idx].tokens = tokens
            messages[idx].durationSeconds = duration
        }
        tokensPerSecond = tps
        isGenerating = false
    }

    private func fail(_ id: UUID, _ message: String) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].isStreaming = false
            messages[idx].error = message
        }
        isGenerating = false
    }

    /// Writes the completed assistant turn to disk.
    private func persistTurn(_ id: UUID,
                             convID: UUID,
                             text: String,
                             reasoning: String,
                             tokens: Int,
                             duration: Double) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        history.append(messages[idx].stored, to: convID)
        history.flush()
    }

    // MARK: Tool execution

    /// A tool block was found in the reply: hold it for confirmation, or run it
    /// straight away if it is non-destructive and confirmation is off.
    private func handleProposedCommand(_ cmd: SandboxTools.ProposedCommand) {
        if cmd.needsConfirmation {
            pendingCommand = cmd
        } else {
            executeCommand(cmd)
        }
    }

    func confirmPendingCommand() {
        guard let cmd = pendingCommand else { return }
        pendingCommand = nil
        executeCommand(cmd)
    }

    func rejectPendingCommand() {
        pendingCommand = nil
        lastToolResult = "已取消该操作"
    }

    private func executeCommand(_ cmd: SandboxTools.ProposedCommand) {
        do {
            let result = try SandboxTools.run(cmd.command, argument: cmd.argument)
            lastToolResult = result
            appendSystemNote("🛠 \(result)")
        } catch {
            lastToolResult = "失败：\(error.localizedDescription)"
            appendSystemNote("⚠️ 工具执行失败：\(error.localizedDescription)")
        }
    }

    /// Adds a visible note to the transcript (tool results, errors).
    private func appendSystemNote(_ text: String) {
        var note = ChatMessage(role: .system, text: text)
        note.timestamp = Date()
        messages.append(note)
        if let convID = conversationID {
            history.append(note.stored, to: convID)
            history.flush()
        }
    }

    /// Strips reasoning into a separate field so the UI can collapse it.
    /// Handles the tag variants emitted by R1-style distill models.
    static func splitReasoning(_ raw: String) -> (String, String) {
        // Tag spellings in the wild for R1 distills. Written as unicode escapes
        // so the source stays ASCII and cannot be damaged by an editor.
        let openTag = "<\u{FF5C}think\u{FF5C}>"
        let closers = ["<\u{FF5C}end\u{2581}of\u{2581}thinking\u{FF5C}>",
                       "<\u{FF5C}/think\u{FF5C}>",
                       "[/THINK]"]

        guard let open = raw.range(of: openTag) else {
            var cleaned = raw
            for c in closers { cleaned = cleaned.replacingOccurrences(of: c, with: "") }
            return (cleaned, "")
        }

        let afterOpen = raw[open.upperBound...]
        for closer in closers {
            if let close = afterOpen.range(of: closer) {
                let reasoning = String(afterOpen[..<close.lowerBound])
                let answer = String(afterOpen[close.upperBound...])
                return (answer.trimmingCharacters(in: .whitespacesAndNewlines), reasoning)
            }
        }
        // Still thinking: keep the answer empty rather than dumping raw reasoning.
        return ("", String(afterOpen))
    }
}
