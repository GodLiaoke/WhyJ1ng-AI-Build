import Foundation
import Combine

// MARK: - Detection history
//
// Rolling record of what the detector has seen, so the chat model can answer
// questions like "刚才有几个人？" or "有人靠近吗？".
//
// Nothing here decides anything on its own: it only accumulates observations
// from the camera screen and the overlay scanner, and renders a compact text
// summary that gets injected as system context.

struct DetectionSample: Codable, Hashable {
    let timestamp: Date
    let personCount: Int
    let totalCount: Int
    /// Largest person box area as a fraction of the frame, a rough proximity cue.
    let maxArea: Double
    let maxConfidence: Double
    let labels: [String]
}

/// Aggregated view used to answer questions.
struct DetectionSummary {
    let windowSeconds: Double
    let peakPeople: Int
    let currentPeople: Int
    let averagePeople: Double
    let totalSightings: Int
    let lastSeen: Date?
    let maxConfidence: Double
    let approaching: Bool
    let labels: [String]

    var isEmpty: Bool { totalSightings == 0 }
}

@MainActor
final class DetectionStore: ObservableObject {
    static let shared = DetectionStore()

    /// Samples newer than this are kept.
    private let retentionSeconds: Double = 600
    /// Observations are folded into a sample at most this often.
    private let sampleInterval: Double = 2.0
    /// Frames are considered "the same sighting" within this gap.
    private let gapSeconds: Double = 5.0

    @Published private(set) var samples: [DetectionSample] = []
    @Published private(set) var live: [Detection] = []
    @Published private(set) var lastUpdate: Date? = nil

    private var lastSampleAt: Date = .distantPast
    private var recentAreas: [Double] = []
    private let maxAreaWindow = 8

    private init() {}

    // MARK: Ingest

    /// Called by the camera screen and the overlay scanner with each result set.
    func record(detections: [Detection], source: String) {
        let now = Date()
        live = detections
        lastUpdate = now

        // Per-sighting bookkeeping runs every call so proximity is responsive.
        let personBoxes = detections.filter { $0.label == "person" }
        let area = personBoxes.map { Double($0.rect.width * $0.rect.height) }.max() ?? 0
        recentAreas.append(area)
        if recentAreas.count > maxAreaWindow { recentAreas.removeFirst() }

        guard now.timeIntervalSince(lastSampleAt) >= sampleInterval else { return }
        lastSampleAt = now

        let sample = DetectionSample(
            timestamp: now,
            personCount: personBoxes.count,
            totalCount: detections.count,
            maxArea: area,
            maxConfidence: Double(personBoxes.map(\.confidence).max() ?? 0),
            labels: Array(Set(detections.map(\.label))).sorted()
        )
        samples.append(sample)
        prune(now: now)
    }

    /// Records an explicit "nothing detected" tick so gaps are visible.
    func recordEmpty(source: String) {
        record(detections: [], source: source)
    }

    func reset() {
        samples.removeAll()
        live.removeAll()
        recentAreas.removeAll()
        lastSampleAt = .distantPast
        lastUpdate = nil
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retentionSeconds)
        if let firstFresh = samples.firstIndex(where: { $0.timestamp >= cutoff }), firstFresh > 0 {
            samples.removeFirst(firstFresh)
        }
        if samples.count > 600 { samples.removeFirst(samples.count - 600) }
    }

    // MARK: Query

    func summary(windowSeconds: Double = 30) -> DetectionSummary {
        let now = Date()
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let window = samples.filter { $0.timestamp >= cutoff }

        // Collapse consecutive non-empty samples into "sightings" so a person
        // standing still does not inflate the count.
        var sightings = 0
        var previous: Date? = nil
        for s in window where s.personCount > 0 {
            if let p = previous, s.timestamp.timeIntervalSince(p) <= gapSeconds {
                previous = s.timestamp
                continue
            }
            sightings += 1
            previous = s.timestamp
        }

        let people = window.map(\.personCount)
        let lastPositive = samples.last(where: { $0.personCount > 0 })?.timestamp

        return DetectionSummary(
            windowSeconds: windowSeconds,
            peakPeople: people.max() ?? 0,
            currentPeople: live.filter { $0.label == "person" }.count,
            averagePeople: people.isEmpty ? 0 : Double(people.reduce(0, +)) / Double(people.count),
            totalSightings: sightings,
            lastSeen: lastPositive,
            maxConfidence: window.map(\.maxConfidence).max() ?? 0,
            approaching: isApproaching(),
            labels: Array(Set(window.flatMap(\.labels))).sorted()
        )
    }

    /// True when the detected box has been growing over the last few frames.
    private func isApproaching() -> Bool {
        let values = recentAreas.filter { $0 > 0 }
        guard values.count >= 4 else { return false }
        let half = values.count / 2
        let early = values.prefix(half).reduce(0, +) / Double(half)
        let late = values.suffix(half).reduce(0, +) / Double(half)
        guard early > 0 else { return late > 0.01 }
        return late > early * 1.25
    }

    // MARK: Context rendering

    /// The block injected into the system prompt, honouring the user's toggles.
    /// Every line is optional because a small model degrades quickly when fed
    /// more context than it can use.
    @MainActor
    func contextBlock(settings: AIContextSettings) -> String {
        guard settings.injectDetection else { return "" }

        let s = summary(windowSeconds: settings.windowSeconds)

        var parts: [String] = []

        if settings.includeCounts {
            var head = "近 \(Int(settings.windowSeconds)) 秒累计出现 \(s.totalSightings) 次目标"
            head += "；当前画面 \(s.currentPeople) 人"
            if s.peakPeople > 0 { head += "；窗口内最多 \(s.peakPeople) 人" }
            parts.append(head)
        }

        if settings.includeLastSeen, let last = s.lastSeen {
            let secs = Int(Date().timeIntervalSince(last))
            parts.append(secs < 60 ? "最后检测到目标：\(secs) 秒前"
                                   : "最后检测到目标：约 \(secs / 60) 分钟前")
        }

        if settings.includeLabels, !s.labels.isEmpty {
            parts.append("识别到的类别：\(s.labels.joined(separator: "、"))")
        }

        if settings.includeProximity, s.currentPeople > 0 {
            parts.append(s.approaching ? "移动趋势：目标正在靠近（画面占比持续增大）"
                                       : "移动趋势：无靠近迹象")
        }

        if settings.includeTrend, s.maxConfidence > 0 {
            parts.append(String(format: "最高置信度：%.2f", s.maxConfidence))
        }

        guard !parts.isEmpty else { return "" }
        return "[检测上下文]\n" + parts.map { "- " + $0 }.joined(separator: "\n")
    }

    /// Backwards-compatible default used where no settings are available.
    func contextBlock() -> String {
        contextBlock(settings: AIContextSettings.shared)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Detailed history for the history tool.
    func historyBlock(limit: Int = 20) -> String {
        let recent = samples.suffix(limit)
        guard !recent.isEmpty else { return "无历史记录。" }
        return recent.map { s in
            "\(Self.timeFormatter.string(from: s.timestamp))  人=\(s.personCount)  目标=\(s.totalCount)"
        }.joined(separator: "\n")
    }
}

// MARK: - Question routing
//
// Small local models are unreliable at function calling, so intent is decided
// by keyword matching and the answer is assembled from the store directly. The
// model is only asked to phrase the result.

enum DetectionIntent {
    case currentCount
    case historyCount
    case approaching
    case describe
    case lastSeen
    case labels
    /// No keyword matched; fall through to the model.
    case unmatched

    /// Returns the intent and, when it can be answered from data alone, a
    /// pre-computed factual answer.
    ///
    /// `@MainActor` because `DetectionStore` is main-actor isolated.
    @MainActor
    static func classify(_ question: String, store: DetectionStore) -> (DetectionIntent, String?) {
        let q = question.lowercased()
        let s = store.summary(windowSeconds: 30)

        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) } }

        let countWords = ["几个", "多少", "人数", "有几人", "几个人", "count", "how many"]
        let currentWords = ["现在", "当前", "此刻", "right now", "currently", "画面"]
        let historyWords = ["刚才", "之前", "过去", "最近", "刚才有", "刚才那", "recently", "earlier", "last"]
        let approachWords = ["靠近", "接近", "过来", "近了", "approach", "coming", "closer"]
        let describeWords = ["描述", "看看", "什么情况", "画面里", "看到什么", "describe", "what do you see"]
        let lastSeenWords = ["最后", "多久", "什么时候", "last seen", "when"]
        let labelWords = ["类别", "什么东西", "什么物体", "label", "what objects"]

        if has(approachWords) {
            return (.approaching, s.currentPeople == 0 && s.lastSeen == nil
                    ? "画面里现在没有人，也没有靠近的迹象。"
                    : (s.approaching ? "有人在靠近：目标在画面中的占比持续增大。"
                                     : "目前没有靠近的迹象。"))
        }
        if has(describeWords) {
            if s.currentPeople == 0 && s.lastSeen == nil {
                return (.describe, "画面里目前没有人。")
            }
            var t = "当前画面有 \(s.currentPeople) 人"
            if s.peakPeople > s.currentPeople { t += "，近 30 秒最多出现过 \(s.peakPeople) 人" }
            t += s.approaching ? "，并且有人正在靠近。" : "。"
            return (.describe, t)
        }
        if has(countWords) && has(currentWords) {
            return (.currentCount, "当前画面有 \(s.currentPeople) 人。")
        }
        if has(countWords) && has(historyWords) {
            return (.historyCount,
                    s.totalSightings == 0
                    ? "近 30 秒没有检测到人。"
                    : "近 30 秒内检测到 \(s.totalSightings) 次人员出现，最多同时 \(s.peakPeople) 人。")
        }
        if has(countWords) {
            // Ambiguous: answer with both frames of reference.
            return (.currentCount,
                    "当前 \(s.currentPeople) 人；近 30 秒累计出现 \(s.totalSightings) 次，最多 \(s.peakPeople) 人。")
        }
        if has(lastSeenWords) {
            guard let last = s.lastSeen else { return (.lastSeen, "这段时间没有检测到人。") }
            let secs = Int(Date().timeIntervalSince(last))
            return (.lastSeen, secs < 60
                    ? "最后一次检测到人是在 \(secs) 秒前。"
                    : "最后一次检测到人是在约 \(secs / 60) 分钟前。")
        }
        if has(labelWords) {
            return (.labels, s.labels.isEmpty ? "没有识别到任何目标。"
                                              : "识别到的类别：\(s.labels.joined(separator: "、"))。")
        }
        return (.unmatched, nil)    }
}
