import Foundation

// MARK: - Chat history store
//
// Persists conversations to a JSON file in the app container. Deliberately not
// SwiftData: the model here is tiny (a list of messages plus the settings that
// produced them), a plain file is trivial to inspect and copy out, and it
// avoids a schema-migration step for a format that will keep changing during
// preview development.

struct ChatConversation: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [StoredMessage]
    /// Model that was selected while this conversation was live.
    var modelName: String

    /// Short line shown in the conversation list.
    /// Named `summaryText` rather than `preview` because `preview` collides
    /// with SwiftUI's `View.preview(_:traits:body:)` overload set.
    ///
    /// `role` is stored as a raw `String`, so it is compared against a string
    /// literal here — writing `.user` sends the compiler looking for a member on
    /// `String` and it resolves into an unrelated Foundation type.
    var summaryText: String {
        messages.last(where: { $0.role == ChatMessage.Role.user.rawValue })?.text
            ?? messages.last?.text
            ?? "空对话"
    }

    var messageCount: Int { messages.count }
}

struct StoredMessage: Codable, Hashable {
    var role: String
    var text: String
    var reasoning: String?
    var timestamp: Date
    var tokens: Int
    var durationSeconds: Double
}

@MainActor
final class ChatHistoryStore: ObservableObject {
    static let shared = ChatHistoryStore()

    @Published private(set) var conversations: [ChatConversation] = []
    @Published private(set) var currentID: UUID?

    private let fileName = "chat-history.json"
    private let maxConversations = 40
    private let maxMessagesPerConversation = 200

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName)
    }

    private init() {
        load()
    }

    // MARK: Current conversation

    var current: ChatConversation? {
        guard let currentID else { return nil }
        return conversations.first { $0.id == currentID }
    }

    /// Starts a fresh conversation and makes it current.
    @discardableResult
    func startNew(modelName: String) -> UUID {
        let conv = ChatConversation(id: UUID(),
                                    title: "",
                                    createdAt: Date(),
                                    updatedAt: Date(),
                                    messages: [],
                                    modelName: modelName)
        conversations.insert(conv, at: 0)
        currentID = conv.id
        save()
        return conv.id
    }

    func select(_ id: UUID) {
        currentID = id
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = conversations.first?.id }
        save()
    }

    func deleteAll() {
        conversations.removeAll()
        currentID = nil
        save()
    }

    // MARK: Mutation

    func append(_ message: StoredMessage, to id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages.append(message)
        conversations[idx].updatedAt = Date()

        // Derive a title from the first user message.
        if conversations[idx].title.isEmpty, message.role == "user" {
            conversations[idx].title = String(message.text.prefix(24))
        }
        if conversations[idx].messages.count > maxMessagesPerConversation {
            let drop = conversations[idx].messages.count - maxMessagesPerConversation
            conversations[idx].messages.removeFirst(drop)
        }
        save()
    }

    /// Replaces the trailing assistant message, used while streaming.
    func updateLastAssistant(_ text: String,
                             reasoning: String?,
                             to id: UUID,
                             tokens: Int,
                             duration: Double) {
        guard let ci = conversations.firstIndex(where: { $0.id == id }),
              let mi = conversations[ci].messages.lastIndex(where: { $0.role == "assistant" })
        else { return }
        conversations[ci].messages[mi].text = text
        conversations[ci].messages[mi].reasoning = reasoning
        conversations[ci].messages[mi].tokens = tokens
        conversations[ci].messages[mi].durationSeconds = duration
        conversations[ci].updatedAt = Date()
        // Streaming updates arrive per token; persisting each one would hammer
        // the disk, so saving is the caller's job at the end of a turn.
    }

    func flush() { save() }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([ChatConversation].self, from: data) else { return }
        conversations = list.sorted { $0.updatedAt > $1.updatedAt }
        currentID = conversations.first?.id
    }

    private func save() {
        if conversations.count > maxConversations {
            conversations = Array(conversations.prefix(maxConversations))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(conversations) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Exported copy for the Files app / sharing.
    var exportURL: URL { fileURL }
}
