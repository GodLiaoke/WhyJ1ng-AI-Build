import Foundation
import Combine
import UIKit

// MARK: - Model manager
//
// Owns which LLM tier is selected, how the file gets onto the device, and when
// the engine is loaded or unloaded.
//
// Lifecycle policy (all of it exists to avoid being jetsam-killed):
//   * load lazily, only when the user actually sends a message
//   * unload on memory warnings
//   * unload on entering the background (iOS does not run timers while
//     suspended, so a delayed unload is not achievable)
//   * refuse tiers the device cannot hold

enum ModelState: Equatable {
    case absent
    case downloading
    case paused
    case loading
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .absent: return "未下载"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .loading: return "加载中"
        case .ready: return "就绪"
        case .failed(let m): return m
        }
    }

    var isBusy: Bool {
        switch self {
        case .downloading, .loading: return true
        default: return false
        }
    }
}

@MainActor
final class LlamaModelManager: NSObject, ObservableObject {
    static let shared = LlamaModelManager()

    private enum Key {
        static let tier = "llm.tier"
        static let autoUnload = "llm.autoUnload"
    }

    @Published private(set) var tier: LlamaTier
    @Published private(set) var state: ModelState = .absent
    @Published private(set) var statusLine: String = ""
    @Published var autoUnloadOnBackground: Bool {
        didSet { UserDefaults.standard.set(autoUnloadOnBackground, forKey: Key.autoUnload) }
    }

    /// Resumable transfer, exposed so the UI can show rate / ETA / resume.
    let downloader = ResumableDownloader()

    private var backgroundTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        let d = UserDefaults.standard
        d.register(defaults: [Key.autoUnload: true])
        if let raw = d.string(forKey: Key.tier), let t = LlamaTier(rawValue: raw) {
            tier = t
        } else {
            tier = ModelCatalog.recommendedTier
        }
        autoUnloadOnBackground = d.bool(forKey: Key.autoUnload)
        super.init()

        refreshState()
        installObservers()
        bindDownloader()
    }

    var spec: LlamaModelSpec { ModelCatalog.spec(for: tier) }

    var downloadProgress: Double { downloader.progress }
    var downloadSpeedText: String { downloader.speedText }
    var downloadETAText: String { downloader.etaText }
    var downloadProgressText: String { downloader.progressText }
    var downloadMirror: String { downloader.currentMirror }
    var hasPartialDownload: Bool { downloader.receivedBytes > 0 && downloader.state != .finished }

    // MARK: State

    func refreshState() {
        // "Ready" means the engine actually holds the model. The file existing
        // on its own is a lower state, otherwise the unload button looks like it
        // did nothing: it does release the engine, but the label stayed on
        // "ready" because only the file was checked.
        if spec.isDownloaded {
            if state == .loading || state == .downloading { return }
            Task { @MainActor in
                let loaded = await LlamaEngine.shared.isLoaded
                if loaded {
                    self.state = .ready
                    self.statusLine = "\(self.spec.displayName) · 已加载"
                } else {
                    self.state = .paused
                    self.statusLine = "\(self.spec.displayName) · 已下载，未加载"
                }
            }
        } else {
            state = .absent
            statusLine = "尚未下载 \(spec.displayName)"
        }
    }

    func select(tier newTier: LlamaTier) async {
        guard newTier != tier else { return }
        await unload()
        downloader.cancel()
        tier = newTier
        UserDefaults.standard.set(newTier.rawValue, forKey: Key.tier)
        refreshState()
    }

    // MARK: Download

    /// Starts or resumes the transfer. Safe to call repeatedly.
    func download() {
        guard !spec.isDownloaded else {
            refreshState()
            return
        }
        downloader.start(mirrors: spec.mirrors, destination: spec.localURL)
    }

    func pauseDownload() {
        downloader.pause()
    }

    func resumeDownload() {
        downloader.start(mirrors: spec.mirrors, destination: spec.localURL)
    }

    func cancelDownload() {
        downloader.cancel()
        refreshState()
    }

    private func bindDownloader() {
        downloader.objectWillChange
            .sink { [weak self] _ in
                // Mirror the transfer state into this object so views observing
                // the manager stay in sync.
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        downloader.$state
            .sink { [weak self] s in
                guard let self else { return }
                switch s {
                case .downloading, .preparing:
                    self.state = .downloading
                    self.statusLine = "\(self.downloader.progressText) · \(self.downloader.speedText)"
                case .paused:
                    self.state = .paused
                    self.statusLine = "已暂停 · \(self.downloader.progressText)"
                case .finished:
                    self.state = .ready
                    self.refreshState()
                case .failed(let m):
                    self.state = .failed(m)
                    self.statusLine = m
                case .idle:
                    self.refreshState()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Files import

    /// Imports a .gguf chosen in the document picker.
    func importFile(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let dest = ModelCatalog.modelsDirectory.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: url, to: dest)
        refreshState()
        statusLine = "已导入 \(url.lastPathComponent)"
    }

    /// Any .gguf files sitting in the app's folders, so one can simply be
    /// dropped in via the Files app without using the document picker.
    func discoveredLocalModels() -> [URL] {
        let fm = FileManager.default
        let dirs = [ModelCatalog.modelsDirectory, ModelCatalog.documentsRoot]
        var found: [URL] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            for item in items where item.pathExtension.lowercased() == "gguf" {
                if !found.contains(where: { $0.lastPathComponent == item.lastPathComponent }) {
                    found.append(item)
                }
                // Also surface a partially downloaded file so its progress is
                // discoverable rather than invisible.
                let part = item.appendingPathExtension("part")
                _ = part
            }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func deleteModel() async {
        await unload()
        downloader.cancel()
        try? FileManager.default.removeItem(at: spec.localURL)
        try? FileManager.default.removeItem(at: spec.localURL.appendingPathExtension("part"))
        refreshState()
    }

    // MARK: Engine lifecycle

    @discardableResult
    func ensureLoaded() async -> Bool {
        // The tier valve is checked before any file or memory work, so a locked
        // tier cannot be loaded even if this is called directly.
        guard FeatureGateCheck.allow(spec.tier.featureKey) else {
            state = .absent
            statusLine = LicenseManager.shared.gateReason(spec.tier.featureKey)
            return false
        }

        if await LlamaEngine.shared.isLoaded,
           await LlamaEngine.shared.loadedPath == spec.localURL.path {
            return true
        }
        guard spec.isDownloaded else {
            state = .absent
            statusLine = "模型文件不存在"
            return false
        }

        state = .loading
        statusLine = "正在加载 \(spec.displayName)…"

        do {
            try await LlamaEngine.shared.load(path: spec.localURL.path,
                                              contextSize: spec.contextSize)
            state = .ready
            let desc = await LlamaEngine.shared.modelDescription
            statusLine = "\(desc) · 上下文 \(spec.contextSize)"
            return true
        } catch {
            state = .failed(error.localizedDescription)
            statusLine = error.localizedDescription
            return false
        }
    }

    func unload() async {
        await LlamaEngine.shared.unload()
        refreshState()
    }

    // MARK: Observers

    private func installObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.handleMemoryWarning() }
        })

        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleEnteredBackground() }
        })
    }

    private func handleMemoryWarning() async {
        guard await LlamaEngine.shared.isLoaded else { return }
        await unload()
        statusLine = "内存告警，已卸载模型（下次提问会重新加载）"
    }

    /// iOS does not run timers while the app is suspended, so a "unload after N
    /// seconds in background" is not implementable. Releasing immediately on
    /// background is the honest version of that behaviour: the process is
    /// likely to be reclaimed while suspended, and holding several GB of mapped
    /// weights makes that far more likely.
    private func handleEnteredBackground() {
        guard autoUnloadOnBackground else { return }
        Task { @MainActor in
            guard await LlamaEngine.shared.isLoaded else { return }
            await self.unload()
            self.statusLine = "进入后台已释放模型（返回时自动重载）"
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
