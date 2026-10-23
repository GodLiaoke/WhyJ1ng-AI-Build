import Foundation
import Combine

// MARK: - App <-> SpringBoard component contract
//
// The SpringBoard component is a closed loop: it captures the screen, runs the
// model, draws the boxes and injects the aim movement, all inside SpringBoard.
// This app is therefore only a configuration editor for it. The single channel
// between the two processes is:
//
//   config      /var/mobile/Library/Preferences/cc.ouovo.yolooverlay.plist
//   reload      Darwin notification  cc.ouovo.yolooverlay.reload
//   heartbeat   /var/mobile/Library/Preferences/cc.ouovo.yolooverlay.alive
//               (the component stamps a unix timestamp every 5 seconds)
//
// The key names below are the frozen contract from SUBAGENT_BRIEF_2.md 3.2 and
// are encoded verbatim — no renaming, no nesting, no wrapper dictionary. Two
// keys are additions, both marked below with "EXTENSION".
//
// WHY A FAILED WRITE MUST BE VISIBLE
//
// `/var/mobile/Library/Preferences/` is outside the app sandbox. On a
// non-jailbroken device every write there fails, and the failure is easy to
// swallow: `try?` and a `print` would leave the panel looking like it saved
// while the component keeps reading the old file (or no file at all). So every
// mutation returns a `ConfigWriteResult`, the panel shows the message, and the
// write is verified by reading it back.

struct YOLOOverlayConfig: Codable, Equatable {

    // MARK: Contract keys (BRIEF_2 3.2)

    /// Master switch for the component.
    var enabled = false
    /// Whether the component draws its overlay boxes.
    var overlay = true
    /// Whether the component injects aim movement.
    var aim = false
    /// Absolute path of the `.mlmodelc` the component loads. Absolute because
    /// the component runs in SpringBoard and cannot resolve the app's sandbox
    /// relative paths.
    var modelPath = ""
    /// Detection confidence threshold, 0...1.
    var confidence = 0.35
    /// Head band height as a fraction of the box height, from the top.
    /// Same meaning as `AimSettings.headHeightFraction`.
    var headHeightFraction = 0.22
    /// Horizontal aim position inside the box: 0 left edge, 1 right edge.
    /// Same meaning as `AimSettings.headWidthFraction`.
    var headWidthFraction = 0.5
    /// Movement speed multiplier. Same meaning as `AimSettings.speed`.
    var speed = 1.0
    /// Smoothing factor 0...1. Same meaning as `AimSettings.smoothing`.
    var smoothing = 0.35
    /// Box colour, `#RRGGBB`. Defaults to the app's `Palette.accent` (#1B5DDB).
    var boxColor = "#1B5DDB"

    // MARK: EXTENSION keys
    //
    // Not in the BRIEF_2 table. `prediction` mirrors `AimSettings.prediction` so
    // the aim tuning in the panel is not missing one of its five sliders; the
    // component ignores it when it does not read the key. `pendingDx` /
    // `pendingDy` come from BRIEF_2 3.4: the aim transport accumulates a
    // displacement here and the component drains it.

    var prediction = 0.15
    var pendingDx = 0.0
    var pendingDy = 0.0

    init() {}

    enum CodingKeys: String, CodingKey {
        case enabled
        case overlay
        case aim
        case modelPath
        case confidence
        case headHeightFraction
        case headWidthFraction
        case speed
        case smoothing
        case boxColor
        case prediction
        case pendingDx
        case pendingDy
    }

    /// Decodes leniently: every key is optional on disk, because a partly
    /// written or hand-edited plist must not take the panel down.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = YOLOOverlayConfig()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        overlay = try container.decodeIfPresent(Bool.self, forKey: .overlay) ?? defaults.overlay
        aim = try container.decodeIfPresent(Bool.self, forKey: .aim) ?? defaults.aim
        modelPath = try container.decodeIfPresent(String.self, forKey: .modelPath) ?? defaults.modelPath
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? defaults.confidence
        headHeightFraction = try container.decodeIfPresent(Double.self, forKey: .headHeightFraction)
            ?? defaults.headHeightFraction
        headWidthFraction = try container.decodeIfPresent(Double.self, forKey: .headWidthFraction)
            ?? defaults.headWidthFraction
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? defaults.speed
        smoothing = try container.decodeIfPresent(Double.self, forKey: .smoothing) ?? defaults.smoothing
        boxColor = try container.decodeIfPresent(String.self, forKey: .boxColor) ?? defaults.boxColor
        prediction = try container.decodeIfPresent(Double.self, forKey: .prediction) ?? defaults.prediction
        pendingDx = try container.decodeIfPresent(Double.self, forKey: .pendingDx) ?? defaults.pendingDx
        pendingDy = try container.decodeIfPresent(Double.self, forKey: .pendingDy) ?? defaults.pendingDy
    }
}

// MARK: - Write result

/// Outcome of one configuration write, with the reason when it failed.
struct ConfigWriteResult: Equatable {
    let ok: Bool
    let message: String
    let path: String

    static func success(path: String) -> ConfigWriteResult {
        ConfigWriteResult(ok: true, message: "已写入", path: path)
    }

    static func failure(_ message: String, path: String) -> ConfigWriteResult {
        ConfigWriteResult(ok: false, message: message, path: path)
    }
}

// MARK: - Config store
//
// Owns the in-memory copy, the file, and the reload notification. Every UI edit
// goes through `update`, which writes immediately: the panel has no save button
// by design, because a configuration the component has not reloaded yet is worse
// than no configuration at all — the panel would be showing values that are not
// in effect.

@MainActor
final class OverlayConfigStore: ObservableObject {
    static let shared = OverlayConfigStore()

    /// Where the plist lives. Taken from `DeviceCapability` so the path exists
    /// in exactly one place in the app.
    static var configPath: String { DeviceCapability.overlayConfigPath }

    /// What happened the last time the file was read.
    enum FileState: Equatable {
        case unknown
        /// No file yet. The component has never been configured, or it is not
        /// installed at all.
        case absent
        case loaded(Date?)
        case unreadable(String)
    }

    @Published private(set) var config = YOLOOverlayConfig()
    @Published private(set) var fileState: FileState = .unknown
    /// Result of the most recent write, shown under the controls.
    @Published private(set) var lastResult: ConfigWriteResult? = nil
    /// True after a successful write, so the panel can say "组件正在使用这份配置".
    @Published private(set) var lastWrittenAt: Date? = nil

    private init() {}

    /// Directory the plist lives in. Used for a cheap proactive hint before the
    /// user starts flipping switches on a device where nothing can be written.
    var destinationWritable: Bool {
        let dir = (Self.configPath as NSString).deletingLastPathComponent
        return FileManager.default.isWritableFile(atPath: dir)
    }

    // MARK: Read

    func load() {
        let url = URL(fileURLWithPath: Self.configPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            config = seedFromAppSettings()
            fileState = .absent
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try PropertyListDecoder().decode(YOLOOverlayConfig.self, from: data)
            config = decoded
            fileState = .loaded(modificationDate(of: url))
        } catch {
            // Keep the panel usable: fall back to the app's own tuning rather
            // than refusing to show anything.
            config = seedFromAppSettings()
            fileState = .unreadable(describe(error))
        }
    }

    // MARK: Write

    /// Applies one edit and writes it immediately.
    @discardableResult
    func update(_ mutate: (inout YOLOOverlayConfig) -> Void) -> ConfigWriteResult {
        var next = config
        mutate(&next)
        let result = write(next)
        config = next
        lastResult = result
        if result.ok {
            lastWrittenAt = Date()
            postReload()
            fileState = .loaded(Date())
        }
        return result
    }

    /// Rewrites the current in-memory configuration.
    @discardableResult
    func save() -> ConfigWriteResult { update { _ in } }

    private func write(_ value: YOLOOverlayConfig) -> ConfigWriteResult {
        var payload = value

        // `pendingDx` / `pendingDy` are a queue, not a setting: the aim
        // transport accumulates into them and the component zeroes them when it
        // consumes the movement. Writing our stale in-memory copy would throw
        // away an injection that has not been applied yet.
        if let onDisk = readDisk() {
            payload.pendingDx = onDisk.pendingDx
            payload.pendingDy = onDisk.pendingDy
        }

        let url = URL(fileURLWithPath: Self.configPath)
        do {
            let encoder = PropertyListEncoder()
            // XML, not binary: the file is a few hundred bytes and being able to
            // read it back with any plist editor is worth more than the bytes.
            encoder.outputFormat = .xml
            let data = try encoder.encode(payload)
            // `.atomic` writes to a temporary file in the same directory and
            // renames it, so a reader never sees a half-written plist.
            try data.write(to: url, options: .atomic)
        } catch {
            return .failure(describe(error), path: Self.configPath)
        }

        // Verify by reading back. A write that reports success but does not
        // survive a re-read happens on odd filesystems, and the user would never
        // learn about it otherwise.
        guard let back = readDisk(),
              back.enabled == payload.enabled,
              back.overlay == payload.overlay,
              back.aim == payload.aim,
              back.modelPath == payload.modelPath else {
            return .failure("写入后读回的内容与配置不一致（可能被其它进程改写）",
                            path: Self.configPath)
        }
        return .success(path: Self.configPath)
    }

    private func readDisk() -> YOLOOverlayConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.configPath)) else {
            return nil
        }
        return try? PropertyListDecoder().decode(YOLOOverlayConfig.self, from: data)
    }

    // MARK: Reload signal

    /// Tells the component to re-read the plist. A Darwin notification carries
    /// no payload, which is exactly why the plist has to be complete before this
    /// is posted.
    func postReload() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(DeviceCapability.overlayReloadNotification as CFString),
            nil, nil, true)
    }

    // MARK: Helpers

    private func modificationDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    /// Turns a write error into something the panel can show.
    ///
    /// The interesting case is the sandboxed one: `NSCocoaErrorDomain` 512/513
    /// is "the file could not be saved" and its localized description is a
    /// generic apology. The POSIX errno underneath is what actually explains it.
    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        let underlyingText = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)
            .map { "（\($0.localizedDescription)）" } ?? ""
        if ns.domain == NSCocoaErrorDomain, ns.code == 513 || ns.code == 512 {
            // The sandboxed case: the app is not allowed to write there at all.
            return "系统拒绝写入：App 沙盒对 Preferences 目录没有写权限" + underlyingText
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == 4 {
            // The directory does not exist and cannot be created from inside the
            // sandbox, which is the other shape of the same failure.
            return "目标目录不存在且无法创建（沙盒限制）" + underlyingText
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return "\(ns.localizedDescription)（errno \(underlying.code)）"
        }
        return ns.localizedDescription
    }

    /// First-run defaults taken from the app's own tuning, so the component
    /// starts from the numbers the user already adjusted in the app instead of
    /// from a second set of defaults that would silently disagree.
    private func seedFromAppSettings() -> YOLOOverlayConfig {
        var seeded = YOLOOverlayConfig()
        let aimSettings = AimController.shared.settings
        seeded.headHeightFraction = aimSettings.headHeightFraction
        seeded.headWidthFraction = aimSettings.headWidthFraction
        seeded.speed = aimSettings.speed
        seeded.smoothing = aimSettings.smoothing
        seeded.prediction = aimSettings.prediction
        seeded.confidence = DetectorSettings.shared.confidence
        if let compiled = ModelLoader.discoverModels().first(where: { $0.isCompiled }) {
            seeded.modelPath = compiled.url.path
        }
        return seeded
    }
}
