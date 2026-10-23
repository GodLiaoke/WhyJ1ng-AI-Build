import Foundation

// MARK: - Model catalog
//
// Three tiers, matching what each device can realistically hold.
//
// Downloads go through `hf-mirror.com` (a HuggingFace mirror reachable from
// mainland China) because the app is used there and `huggingface.co` itself is
// not reliably reachable. Every entry also has a ModelScope fallback for the
// models that publish there.

enum LlamaTier: String, CaseIterable, Identifiable, Codable {
    case lite
    case pro
    case max

    /// Server-side valve for this tier. Each tier is gated separately, so
    /// a VIP user gets the light model without unlocking the flagship one.
    var featureKey: String {
        switch self {
        case .lite: return "model_lite"
        case .pro:  return "model_pro"
        case .max:  return "model_max"
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lite: return "超轻量"
        case .pro: return "性能"
        case .max: return "极致"
        }
    }

    /// Minimum physical RAM the device should have for this tier to be sane.
    /// Below this the app disables the tier rather than letting iOS jetsam-kill
    /// the process mid-conversation.
    var minimumRAMGB: Double {
        switch self {
        case .lite: return 4.0
        case .pro: return 6.0
        case .max: return 8.0
        }
    }
}

struct LlamaModelSpec: Identifiable, Hashable {
    let tier: LlamaTier
    let displayName: String
    let fileName: String
    let approxBytes: Int64
    let contextSize: UInt32
    /// Remote mirrors, tried in order.
    let mirrors: [URL]
    let note: String

    var id: String { tier.rawValue }

    var sizeText: String {
        String(format: "%.2f GB", Double(approxBytes) / 1_073_741_824.0)
    }

    /// Local path inside the app container.
    var localURL: URL { ModelCatalog.modelsDirectory.appendingPathComponent(fileName) }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }

    var installedBytes: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

enum ModelCatalog {

    // MARK: Storage

    /// Models live in Documents/LLMModels so they are visible in the Files app
    /// and survive until the container is reset. (A Sideload reinstall wipes the
    /// container, hence the resume/re-download path.)
    static var documentsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var modelsDirectory: URL {
        let dir = documentsRoot.appendingPathComponent("LLMModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Specs

    static let all: [LlamaModelSpec] = [
        LlamaModelSpec(
            tier: .lite,
            displayName: "Qwen2.5-1.5B-Instruct",
            fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            approxBytes: 1_065_600_000,
            contextSize: 4096,
            mirrors: [
                URL(string: "https://hf-mirror.com/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
                URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
            ],
            note: "开箱即用 · 响应最快"
        ),
        LlamaModelSpec(
            tier: .pro,
            displayName: "Qwen3-4B-Instruct-2507",
            fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            approxBytes: 2_500_000_000,
            contextSize: 4096,
            mirrors: [
                URL(string: "https://hf-mirror.com/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
                URL(string: "https://hf-mirror.com/Qwen/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
            ],
            note: "更强推理 · 需 2.5GB 空间"
        ),
        LlamaModelSpec(
            tier: .max,
            displayName: "DeepSeek-R1-Distill-Qwen-7B",
            fileName: "DeepSeek-R1-Distill-Qwen-7B-IQ4_XS.gguf",
            approxBytes: 3_700_000_000,
            contextSize: 2048,
            mirrors: [
                URL(string: "https://hf-mirror.com/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-IQ4_XS.gguf")!,
                URL(string: "https://hf-mirror.com/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf")!,
            ],
            note: "推理最强 · 需 8GB+ 机型"
        ),
    ]

    static func spec(for tier: LlamaTier) -> LlamaModelSpec {
        all.first { $0.tier == tier } ?? all[0]
    }

    // MARK: Device capability

    static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    }

    /// Highest usable tier on this device, chosen from physical RAM.
    static var recommendedTier: LlamaTier {
        let ram = physicalMemoryGB
        if ram >= 7.5 { return .max }
        if ram >= 5.5 { return .pro }
        return .lite
    }

    static func isSupported(_ tier: LlamaTier) -> Bool {
        physicalMemoryGB >= tier.minimumRAMGB - 0.25
    }
}
