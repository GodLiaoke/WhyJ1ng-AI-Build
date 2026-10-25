import Foundation
import Combine

// MARK: - Custom model store
//
// Handles GGUF files the user imported themselves. These are not one of the
// three catalog tiers, so they need their own activation path: the tier system
// is keyed on `LlamaTier`, and a dropped-in file has no tier.
//
// One custom model can be active at a time. Activating one takes precedence
// over the tier selection, and deactivating falls back to the tier.

@MainActor
final class CustomModelStore: ObservableObject {
    static let shared = CustomModelStore()

    private enum Key {
        static let activePath = "llm.custom.activePath"
        static let contextSize = "llm.custom.contextSize"
    }

    /// The imported file currently in use, if any.
    @Published private(set) var activeURL: URL? = nil
    @Published private(set) var isLoaded = false
    @Published private(set) var statusLine: String = ""

    /// Context size for imported models. Their metadata is unknown up front, so
    /// this is conservative: oversized contexts are the fastest way to run out
    /// of memory on an 8GB device.
    @Published var contextSize: UInt32 {
        didSet { UserDefaults.standard.set(Int(contextSize), forKey: Key.contextSize) }
    }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [Key.contextSize: 4096])
        contextSize = UInt32(d.integer(forKey: Key.contextSize))

        if let path = d.string(forKey: Key.activePath) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                activeURL = url
            } else {
                // File was deleted (reinstall, or the user removed it).
                d.removeObject(forKey: Key.activePath)
            }
        }
    }

    var isActive: Bool { activeURL != nil }

    // MARK: Activation

    /// Loads an imported GGUF and makes it the model the chat uses.
    func activate(_ url: URL) async {
        statusLine = "正在加载 \(url.lastPathComponent)…"

        // Switching models must release the previous one first: two loaded
        // models would not both fit on a phone.
        await LlamaEngine.shared.unload()

        do {
            try await LlamaEngine.shared.load(path: url.path, contextSize: contextSize)
            activeURL = url
            isLoaded = true
            UserDefaults.standard.set(url.path, forKey: Key.activePath)
            let desc = await LlamaEngine.shared.modelDescription
            statusLine = "\(desc) · 上下文 \(contextSize)"
        } catch {
            activeURL = nil
            isLoaded = false
            statusLine = "加载失败：\(error.localizedDescription)"
        }
    }

    func deactivate() async {
        await LlamaEngine.shared.unload()
        isLoaded = false
        statusLine = ""
        UserDefaults.standard.removeObject(forKey: Key.activePath)
        activeURL = nil
    }

    /// Called when the tier selection changes, so a stale custom model does not
    /// silently keep answering.
    func invalidateIfActive() async {
        guard isActive else { return }
        await deactivate()
    }

    func delete(_ url: URL) async {
        if activeURL?.path == url.path {
            await deactivate()
        }
        try? FileManager.default.removeItem(at: url)
    }
}
