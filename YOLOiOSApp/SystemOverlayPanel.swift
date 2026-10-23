import SwiftUI
import UIKit
import Combine

// MARK: - System overlay panel
//
// The App-side control surface for the SpringBoard component (route C).
//
// The component decides nothing on its own: it reads the plist, obeys it, and
// stamps a heartbeat so this panel can tell whether it is running at all. That
// makes the panel's job narrow and honest:
//
//   * say what is actually observable (heartbeat age, jailbreak state),
//   * edit the plist and tell the component to reload,
//   * show the write result, because on a non-jailbroken device every write to
//     that path fails and silence would look like success.
//
// WHAT THIS PANEL DOES NOT DO
//
// It does not capture, detect, draw or aim. All of that happens in SpringBoard;
// this process cannot read another app's pixels and cannot inject touches, which
// is the entire reason the component exists. The tuning sliders therefore change
// what the component will do, not what the app does.

@MainActor
struct SystemOverlayPage: View {
    @ObservedObject private var state = OverlayState.shared
    @ObservedObject private var store = OverlayConfigStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if DeviceCapability.supportsSystemOverlay {
                statusSection
                switchSection
                modelSection
                aimSection
                detectionSection
                writeSection
            } else {
                unavailableSection
                writeSection
            }
        }
        .onAppear {
            store.load()
            state.refreshSystemOverlay()
            state.startSystemOverlayMonitor()
        }
    }

    // MARK: Unavailable

    /// Shown instead of the controls when the device cannot host the component.
    ///
    /// Deliberately not a disabled copy of the full panel: switches that cannot
    /// take effect are worse than no switches, because a user who flips them
    /// reasonably concludes the feature is broken rather than unsupported.
    private var unavailableSection: some View {
        CheatSection(title: "系统级悬浮") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(CheatPalette.warn)
                    Text("不可用")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(CheatPalette.warn)
                }
                Text(unavailableReason)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(CheatPalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("跨 App 的浮窗、识别与瞄准全部由 SpringBoard 进程里的组件完成，"
                     + "这需要越狱。本 App 内的悬浮和扫描不受影响。")
                    .font(.system(size: 9))
                    .foregroundColor(CheatPalette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Text(DeviceCapability.summary)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(CheatPalette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CheatPalette.warnDim)
            )
        }
    }

    private var unavailableReason: String {
        if !DeviceCapability.isJailbroken {
            return "当前 iOS \(DeviceCapability.osVersion) 未越狱，无法向 SpringBoard 注入组件。"
        }
        return "设备已越狱，但没有检测到可用的 SpringBoard 注入环境。"
    }

    // MARK: Status

    private var statusSection: some View {
        CheatSection(title: "组件状态") {
            VStack(spacing: 4) {
                CheatStat(k: "状态", v: state.systemOverlayStatusText,
                          tint: state.systemOverlayOnline ? CheatPalette.accent : CheatPalette.warn)
                CheatStat(k: "心跳", v: heartbeatText)
                CheatStat(k: "注入点击", v: DeviceCapability.supportsTouchInjection ? "可用" : "不可用")
                CheatStat(k: "总开关", v: store.config.enabled ? "ON" : "OFF",
                          tint: store.config.enabled ? CheatPalette.accent : CheatPalette.textDim)
                if !state.systemOverlayOnline {
                    Text("组件没在跑时，下面的改动只会写进配置文件，不会生效。")
                        .font(.system(size: 9))
                        .foregroundColor(CheatPalette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                HStack(spacing: 5) {
                    CheatButton(title: "重新读取", icon: "arrow.clockwise") {
                        store.load()
                        state.refreshSystemOverlay()
                    }
                    CheatButton(title: "重发通知", icon: "paperplane") {
                        store.postReload()
                    }
                }
                .padding(.top, 3)
            }
        }
    }

    private var heartbeatText: String {
        guard let age = state.systemOverlayHeartbeatAge else { return "无" }
        if age < 60 { return String(format: "%.0f 秒前", age) }
        return String(format: "%.0f 分钟前", age / 60)
    }

    // MARK: Switches

    private var switchSection: some View {
        CheatSection(title: "开关") {
            VStack(spacing: 8) {
                boolRow("组件总开关", \.enabled)
                boolRow("画框", \.overlay)
                boolRow("自瞄", \.aim)
                Text("自瞄由组件在 SpringBoard 内注入触摸实现；App 进程只写开关。")
                    .font(.system(size: 9))
                    .foregroundColor(CheatPalette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One toggle bound straight to the plist, written on change.
    private func boolRow(_ label: String,
                         _ keyPath: WritableKeyPath<YOLOOverlayConfig, Bool>) -> some View {
        CheatToggle(label: label, isOn: Binding(
            get: { store.config[keyPath: keyPath] },
            set: { newValue in
                _ = store.update { $0[keyPath: keyPath] = newValue }
            }))
    }

    // MARK: Model

    private var modelSection: some View {
        CheatSection(title: "识别模型") {
            VStack(alignment: .leading, spacing: 5) {
                if compiledModels.isEmpty {
                    Text("没有找到 .mlmodelc。先在「模型」页导入并编译一个模型。")
                        .font(.system(size: 10))
                        .foregroundColor(CheatPalette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(compiledModels) { item in
                        CheatRadio(label: item.name,
                                   detail: store.config.modelPath == item.url.path
                                            ? "已选用"
                                            : item.sizeText,
                                   selected: store.config.modelPath == item.url.path) {
                            _ = store.update { $0.modelPath = item.url.path }
                        }
                    }
                }

                if !store.config.modelPath.isEmpty {
                    Text(store.config.modelPath)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(pathReadable ? CheatPalette.textDim : CheatPalette.danger)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    if !pathReadable {
                        Text("这个路径现在读不到：组件会加载失败。重新选一个模型。")
                            .font(.system(size: 9))
                            .foregroundColor(CheatPalette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("组件在 SpringBoard 进程里按这个绝对路径加载，所以只能选已经编译好的 .mlmodelc。")
                    .font(.system(size: 9))
                    .foregroundColor(CheatPalette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pathReadable: Bool {
        let path = store.config.modelPath
        guard !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Compiled models the component can load.
    ///
    /// `discoverModels()` covers Documents, the bundle and the model folder, but
    /// the compiled products the app itself loads are cached in Caches, which it
    /// does not scan — so both are collected here. Only `.mlmodelc` is offered:
    /// an uncompiled `.mlpackage` cannot be loaded from SpringBoard, where there
    /// is no VisionCoreML compile step to fall back on.
    private var compiledModels: [ModelItem] {
        var seen = Set<String>()
        var items: [ModelItem] = []

        for item in ModelLoader.discoverModels() where item.isCompiled {
            guard seen.insert(item.url.path).inserted else { continue }
            items.append(item)
        }

        let cache = ModelLoader.compiledCacheDir
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for dir in entries {
                let nested = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                for url in nested where url.pathExtension.lowercased() == "mlmodelc" {
                    guard seen.insert(url.path).inserted else { continue }
                    items.append(ModelItem(id: url.path,
                                           url: url,
                                           name: url.lastPathComponent,
                                           byteSize: 0,
                                           isBundled: false))
                }
            }
        }

        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Aim tuning

    /// Ranges and meanings are those of `AimSettings` / `AimSettingsView`, so the
    /// numbers in this panel and the numbers in the app's own aim settings mean
    /// the same thing.
    private var aimSection: some View {
        CheatSection(title: "瞄准参数") {
            VStack(alignment: .leading, spacing: 9) {
                ConfigSlider(label: "头部高度占比",
                             keyPath: \.headHeightFraction,
                             initial: store.config.headHeightFraction,
                             range: 0.08...0.45,
                             step: 0.01,
                             format: "%.2f")
                ConfigSlider(label: "头部水平位置",
                             keyPath: \.headWidthFraction,
                             initial: store.config.headWidthFraction,
                             range: 0.2...0.8,
                             step: 0.01,
                             format: "%.2f")
                ConfigSlider(label: "速度",
                             keyPath: \.speed,
                             initial: store.config.speed,
                             range: 0.1...3.0,
                             step: 0.05,
                             format: "%.2f")
                ConfigSlider(label: "平滑",
                             keyPath: \.smoothing,
                             initial: store.config.smoothing,
                             range: 0.0...0.8,
                             step: 0.01,
                             format: "%.2f")
                ConfigSlider(label: "预判",
                             keyPath: \.prediction,
                             initial: store.config.prediction,
                             range: 0.0...1.0,
                             step: 0.01,
                             format: "%.2f")
                Text("瞄准点 = 框顶部往下「头部高度占比 ÷ 2」处，水平取「头部水平位置」；"
                     + "默认 0.22 即头顶往下 11% 处、框的水平中线。")
                    .font(.system(size: 9))
                    .foregroundColor(CheatPalette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("预判 在本轮契约里没有对应的 plist 键，组件不读它时会忽略。")
                    .font(.system(size: 9))
                    .foregroundColor(CheatPalette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detectionSection: some View {
        CheatSection(title: "识别阈值") {
            VStack(alignment: .leading, spacing: 9) {
                ConfigSlider(label: "置信度",
                             keyPath: \.confidence,
                             initial: store.config.confidence,
                             range: 0.1...0.9,
                             step: 0.01,
                             format: "%.2f")
                Text("组件按这个阈值筛掉低置信度的框；越低越灵敏，也越容易误检。")
                    .font(.system(size: 9))
                    .foregroundColor(CheatPalette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Write feedback

    /// The honest half of the panel: what happened to the file.
    private var writeSection: some View {
        CheatSection(title: "配置文件") {
            VStack(alignment: .leading, spacing: 5) {
                Text(OverlayConfigStore.configPath)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(CheatPalette.textDim)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text(fileStateText)
                    .font(.system(size: 9))
                    .foregroundColor(CheatPalette.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                if let result = store.lastResult {
                    HStack(spacing: 5) {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(result.message)
                            .font(.system(size: 9, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(result.ok ? CheatPalette.accent : CheatPalette.danger)
                }

                if !store.destinationWritable {
                    Text("目标目录不可写：未越狱设备的沙盒拿不到 /var/mobile/Library/Preferences 的写权限。"
                         + "改动会显示在这里，但写不进文件，组件也就收不到 —— 上面的失败提示就是这句话的证据。")
                        .font(.system(size: 9))
                        .foregroundColor(CheatPalette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var fileStateText: String {
        switch store.fileState {
        case .unknown:
            return "尚未读取"
        case .absent:
            return "配置文件尚未创建（改动会创建它）"
        case .loaded(let date):
            guard let date else { return "已读取" }
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return "已读取 · 最后修改 \(f.string(from: date))"
        case .unreadable(let why):
            return "读取失败：\(why)"
        }
    }
}

// MARK: - Config slider
//
// A slider that writes to the plist, throttled.
//
// A raw two-way binding would write on every drag event — dozens of plist
// encodes, atomic renames and Darwin notifications per second, each one waking
// SpringBoard to re-read a file. Instead the slider edits local state and the
// write fires once the value has been still for a moment.

@MainActor
private struct ConfigSlider: View {
    let label: String
    let keyPath: WritableKeyPath<YOLOOverlayConfig, Double>
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    @ObservedObject private var store = OverlayConfigStore.shared
    @State private var draft: Double
    @State private var debounce: Task<Void, Never>? = nil

    /// `initial` is passed in rather than read from the store here: a View's
    /// `init` is not guaranteed to run on the main actor, and the store is
    /// main-actor isolated.
    init(label: String,
         keyPath: WritableKeyPath<YOLOOverlayConfig, Double>,
         initial: Double,
         range: ClosedRange<Double>,
         step: Double,
         format: String) {
        self.label = label
        self.keyPath = keyPath
        self.range = range
        self.step = step
        self.format = format
        _draft = State(initialValue: initial)
    }

    var body: some View {
        CheatSlider(label: label,
                    value: $draft,
                    range: range,
                    step: step,
                    display: String(format: format, draft))
            .onChangeCompat(of: draft) { _, newValue in
                debounce?.cancel()
                debounce = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    guard !Task.isCancelled else { return }
                    _ = store.update { $0[keyPath: keyPath] = newValue }
                }
            }
            // Adopt values that arrive from outside (the "重新读取" button, or
            // the component zeroing the pending queue). The tolerance keeps our
            // own write from nudging a slider the user is still dragging.
            .onChangeCompat(of: store.config[keyPath: keyPath]) { _, storedValue in
                if abs(storedValue - draft) > step / 2 {
                    draft = storedValue
                }
            }
    }
}
