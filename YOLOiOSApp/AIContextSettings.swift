import Foundation
import Combine

// MARK: - AI context settings
//
// Controls what detection information is injected into the model's system
// prompt, and lets the user write the surrounding instructions themselves.
//
// Why this matters: a 1.5B model has very little spare capacity. Feeding it a
// large context block on every turn, or instructions that contradict each other,
// measurably degrades its answers. Being able to turn pieces off — and to edit
// the wording — is the difference between a useful assistant and a confused one.

@MainActor
final class AIContextSettings: ObservableObject {
    static let shared = AIContextSettings()

    private enum Key {
        static let enabled = "ai.ctx.enabled"
        static let includeCounts = "ai.ctx.counts"
        static let includeTrend = "ai.ctx.trend"
        static let includeLabels = "ai.ctx.labels"
        static let includeLastSeen = "ai.ctx.lastSeen"
        static let includeProximity = "ai.ctx.proximity"
        static let windowSeconds = "ai.ctx.window"
        static let systemPrompt = "ai.ctx.systemPrompt"
        static let answerStyle = "ai.ctx.style"
        static let allowFileTools = "ai.ctx.fileTools"
        static let toolsRequireConfirm = "ai.ctx.confirm"
    }

    /// Master switch. Off means the model gets no detection data at all, which is
    /// the right setting for general conversation.
    @Published var injectDetection: Bool {
        didSet { UserDefaults.standard.set(injectDetection, forKey: Key.enabled) }
    }

    @Published var includeCounts: Bool {
        didSet { UserDefaults.standard.set(includeCounts, forKey: Key.includeCounts) }
    }
    @Published var includeTrend: Bool {
        didSet { UserDefaults.standard.set(includeTrend, forKey: Key.includeTrend) }
    }
    @Published var includeLabels: Bool {
        didSet { UserDefaults.standard.set(includeLabels, forKey: Key.includeLabels) }
    }
    @Published var includeLastSeen: Bool {
        didSet { UserDefaults.standard.set(includeLastSeen, forKey: Key.includeLastSeen) }
    }
    @Published var includeProximity: Bool {
        didSet { UserDefaults.standard.set(includeProximity, forKey: Key.includeProximity) }
    }

    /// How many seconds of history the summary covers.
    @Published var windowSeconds: Double {
        didSet { UserDefaults.standard.set(windowSeconds, forKey: Key.windowSeconds) }
    }

    /// The system instruction itself. Editable so the wording can be tuned for
    /// whatever model is loaded.
    @Published var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: Key.systemPrompt) }
    }

    /// How long an answer should be.
    @Published var answerStyle: AnswerStyle {
        didSet { UserDefaults.standard.set(answerStyle.rawValue, forKey: Key.answerStyle) }
    }

    /// Allow the model to read/write files inside its own sandbox.
    @Published var allowFileTools: Bool {
        didSet { UserDefaults.standard.set(allowFileTools, forKey: Key.allowFileTools) }
    }

    /// Require a confirmation tap before any tool actually runs.
    @Published var toolsRequireConfirmation: Bool {
        didSet { UserDefaults.standard.set(toolsRequireConfirmation, forKey: Key.toolsRequireConfirm) }
    }

    enum AnswerStyle: String, CaseIterable, Identifiable {
        case brief
        case normal
        case detailed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .brief: return "简短"
            case .normal: return "标准"
            case .detailed: return "详细"
            }
        }

        var instruction: String {
            switch self {
            case .brief: return "回答控制在一句话以内，只给结论。"
            case .normal: return "回答控制在两到三句话以内。"
            case .detailed: return "可以展开说明，但仍要简洁。"
            }
        }
    }

    static let defaultSystemPrompt = """
    你是一个运行在 iPhone 本地的离线视觉助手。你能依据下面提供的检测数据回答问题，\
    但不要编造数据之外的内容，也不要声称自己能看到图像本身。
    """

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Key.enabled: true,
            Key.includeCounts: true,
            Key.includeTrend: true,
            Key.includeLabels: true,
            Key.includeLastSeen: true,
            Key.includeProximity: true,
            Key.windowSeconds: 30.0,
            Key.systemPrompt: Self.defaultSystemPrompt,
            Key.answerStyle: AnswerStyle.normal.rawValue,
            Key.allowFileTools: true,
            Key.toolsRequireConfirm: true,
        ])

        injectDetection = d.bool(forKey: Key.enabled)
        includeCounts = d.bool(forKey: Key.includeCounts)
        includeTrend = d.bool(forKey: Key.includeTrend)
        includeLabels = d.bool(forKey: Key.includeLabels)
        includeLastSeen = d.bool(forKey: Key.includeLastSeen)
        includeProximity = d.bool(forKey: Key.includeProximity)
        windowSeconds = d.double(forKey: Key.windowSeconds)
        systemPrompt = d.string(forKey: Key.systemPrompt) ?? Self.defaultSystemPrompt
        answerStyle = AnswerStyle(rawValue: d.string(forKey: Key.answerStyle) ?? "") ?? .normal
        allowFileTools = d.bool(forKey: Key.allowFileTools)
        toolsRequireConfirmation = d.bool(forKey: Key.toolsRequireConfirm)
    }

    func reset() {
        injectDetection = true
        includeCounts = true
        includeTrend = true
        includeLabels = true
        includeLastSeen = true
        includeProximity = true
        windowSeconds = 30
        systemPrompt = Self.defaultSystemPrompt
        answerStyle = .normal
        allowFileTools = true
        toolsRequireConfirmation = true
    }

    /// Rough size of the context block, for the UI's token estimate.
    var estimatedTokens: Int { max(1, contextPreview.count / 3) }

    /// Renders the block exactly as it will be sent, so the user can see the
    /// effect of each toggle.
    var contextPreview: String {
        DetectionStore.shared.contextBlock(settings: self)
    }
}
