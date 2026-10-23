import SwiftUI
import UIKit
import Combine

// MARK: - Overlay state
// Drives the floating "cheat menu" panel and the screen-scanning loop.
//
// NOTE ON SCOPE: today this scans only this app's own windows. The scanning
// entry point (`captureSourceWindow()`) is deliberately isolated so a future
// TrollStore / cross-process build can swap in a system-wide capture source
// without touching the UI or the detection pipeline.
//
// The cross-process route lives in the SpringBoard component instead of here:
// the component captures, infers, draws and injects inside SpringBoard, and this
// process only edits its configuration. `systemOverlay*` below is the App's view
// of whether that component is alive.

@MainActor
final class OverlayState: ObservableObject {
    static let shared = OverlayState()

    /// Is the floating button on screen at all.
    @Published var isVisible = false
    /// Is the cheat menu expanded.
    @Published var menuExpanded = false
    /// Is the continuous screen scanner running.
    @Published var scanning = false
    /// Boxes from the last screen scan, in screen-point coordinates.
    @Published var screenDetections: [Detection] = []
    /// Draw the boxes over the whole screen instead of only in the panel.
    @Published var drawOnScreen = true
    /// Scan cadence in seconds.
    @Published var interval: Double = 0.7
    /// Last scan cost in milliseconds.
    @Published var lastScanMs: Double = 0
    /// Frames scanned since scanning started.
    @Published var framesScanned = 0
    /// Non-fatal scan error to surface in the panel.
    @Published var lastError: String? = nil

    // MARK: SpringBoard component
    //
    // The component stamps a heartbeat file every 5 seconds. Everything here is
    // derived from that file plus the capability probes, so the panel can only
    // ever claim what is actually observable — the old "系统级悬浮 · Kernel 可用"
    // label was shown on devices where neither was true.

    /// True when the component is installed *and* its heartbeat is fresh.
    @Published private(set) var systemOverlayOnline = false
    /// Age of the last heartbeat in seconds, nil when no heartbeat exists.
    @Published private(set) var systemOverlayHeartbeatAge: TimeInterval? = nil
    /// When the heartbeat was last read, for the "checked Ns ago" line.
    @Published private(set) var systemOverlayCheckedAt: Date? = nil

    /// Target selection ("tap the thing YOLO found").
    /// When on, the overlay punches a hole in its own hit-testing over every
    /// detected target, so a tap lands on the app underneath instead of the
    /// overlay window.
    @Published private(set) var tapToSelectEnabled = false
    /// The most recent target the user tapped, shown as a marker.
    @Published var lastTappedTarget: Detection? = nil
    @Published var lastTappedAt: Date? = nil

    /// True while the launch-mode picker is on screen, before the panel appears.
    @Published var showingLaunchPicker = false

    /// The app window the scanner reads from. Wired up at launch.
    weak var sourceWindow: UIWindow?

    /// Applies the user's saved "tap target" preference when the overlay opens.
    func applySavedPreferences() {
        let wantsTapThrough = DetectorSettings.shared.overlayTapThrough
        if wantsTapThrough && scanning {
            setTapToSelectEnabled(true)
        }
    }

    /// Mirrors `AppState` model info. The overlay runs in its own `UIWindow`
    /// and cannot read the main window's SwiftUI environment, so the values it
    /// needs are republished here.
    @Published var models: [ModelItem] = []
    @Published var selectedModelID: String? = nil

    /// Back-reference used to push selections back into the app.
    private weak var appState: AppState?

    private var timer: Timer?
    private var heartbeatTimer: Timer?
    private var engine: YOLOViewModel?
    private var loadedModelPath: String?
    private var inFlight = false

    private init() {}

    // MARK: SpringBoard component status

    /// Reads the heartbeat once. Cheap enough to call from a button, and called
    /// on a 5 second timer while the panel is up.
    func refreshSystemOverlay() {
        let stamp = DeviceCapability.heartbeatTimestamp
        systemOverlayHeartbeatAge = stamp.map { Date().timeIntervalSince1970 - $0 }
        systemOverlayOnline = DeviceCapability.supportsSystemOverlay
            && DeviceCapability.systemOverlayLoaded
        systemOverlayCheckedAt = Date()
    }

    /// Starts the 5 second heartbeat poll.
    ///
    /// Runs only while the overlay is on screen: the component's state cannot
    /// change while the user is elsewhere in the app, and a permanent timer
    /// waking the main run loop every 5 seconds is not free.
    func startSystemOverlayMonitor() {
        refreshSystemOverlay()
        guard heartbeatTimer == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemOverlay() }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    func stopSystemOverlayMonitor() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// One line for the UI. States what was observed, never what was hoped for.
    var systemOverlayStatusText: String {
        if !DeviceCapability.supportsSystemOverlay {
            return "不可用 · iOS \(DeviceCapability.osVersion) \(DeviceCapability.isJailbroken ? "环境不足以注入 SpringBoard" : "未越狱")"
        }
        if systemOverlayOnline {
            if let age = systemOverlayHeartbeatAge {
                return "已加载 · 心跳 \(Int(age.rounded())) 秒前"
            }
            return "已加载"
        }
        if let age = systemOverlayHeartbeatAge {
            return "已停止 · 最后一次心跳 \(Int(age.rounded())) 秒前"
        }
        return "未安装 · 没有心跳文件"
    }

    // MARK: Lifecycle

    /// Hands the shared inference engine to the overlay. The engine instance is
    /// owned by the app so the camera screen, the photo screen and the overlay
    /// reuse one loaded model instead of each compiling/loading their own copy.
    func attach(engine: YOLOViewModel, app: AppState) {
        self.engine = engine
        self.appState = app
        syncModels()
    }

    /// Pulls the model list out of `AppState` into the overlay's own publishers.
    func syncModels() {
        guard let appState else { return }
        models = appState.models
        if let current = appState.selectedModel,
           models.contains(where: { $0.id == current.id }) {
            selectedModelID = current.id
        } else {
            selectedModelID = models.first?.id
        }
    }

    var selectedModel: ModelItem? {
        models.first { $0.id == selectedModelID } ?? models.first
    }

    func selectModel(_ item: ModelItem) {
        appState?.select(item)
        selectedModelID = item.id
    }

    var isEngineReady: Bool { engine?.isReady ?? false }

    /// Loads `model` into the shared engine when it is not already loaded.
    func prepareEngine(with model: ModelItem) async -> Bool {
        guard let engine else {
            lastError = "推理引擎未就绪"
            return false
        }
        if engine.isReady && loadedModelPath == model.url.path {
            return true
        }
        await engine.load(from: model.url)
        loadedModelPath = model.url.path
        if !engine.isReady {
            lastError = engine.errorMessage ?? "模型加载失败"
            return false
        }
        // Switching models invalidates every previous track.
        screenDetections = []
        return true
    }

    func toggleMenu() {
        // The overlay view recomputes the interactive rectangles when
        // `menuExpanded` changes, so nothing to do here but flip the flag.
        withAnimation(DS.Motion.spring) { menuExpanded.toggle() }
    }

    /// Shows the overlay window, creating it if necessary.
    ///
    /// The launch mode is chosen first: it decides the window level and whether
    /// the kernel layer may be touched, so it cannot be decided afterwards.
    @discardableResult
    func showOverlay() -> Bool {
        let store = LaunchModeStore.shared
        if store.needsSelection {
            // The picker is presented by the overlay root; the window has to
            // exist for that, so it is created here and the panel stays hidden
            // until a mode is committed.
            guard OverlayManager.shared.present() else {
                lastError = "无法创建悬浮窗（无可用窗口场景）"
                isVisible = false
                return false
            }
            showingLaunchPicker = true
            isVisible = true
            return true
        }
        return presentWithCurrentMode()
    }

    /// Presents the overlay using the already-committed mode.
    @discardableResult
    func presentWithCurrentMode() -> Bool {
        guard let mode = LaunchModeStore.shared.active else { return false }

        // `present` adjusts the level of a live window in place, so no teardown
        // is needed here — and doing one would be actively harmful, because the
        // deferred teardown races the rebuild.
        let ok = OverlayManager.shared.present(level: mode.windowLevelOverride)
        isVisible = ok

        if ok {
            applySavedPreferences()
            startSystemOverlayMonitor()
            // Only the unsandboxed mode has any reason to touch the kernel.
            if mode.attemptsKernel {
                KernelExploitRunner.shared.run()
            }
        } else {
            lastError = "无法创建悬浮窗（无可用窗口场景）"
        }
        return ok
    }

    /// Records the picker's choice and brings the panel up.
    func commitLaunchMode(_ mode: LaunchMode) {
        showingLaunchPicker = false
        _ = presentWithCurrentMode()
        if let warn = LaunchModeStore.shared.warning {
            lastError = warn
        }
    }

    func cancelLaunchPicker() {
        showingLaunchPicker = false
        isVisible = false
        OverlayManager.shared.dismiss()
    }

    /// Hides the overlay and stops any scan in progress.
    ///
    /// Teardown itself is deferred inside `OverlayManager.dismiss()`: destroying
    /// the window that is dispatching the current touch crashes in UIKit.
    func hideOverlay() {
        stopScanning()
        menuExpanded = false
        isVisible = false
        setTapToSelectEnabled(false)
        stopSystemOverlayMonitor()
        OverlayManager.shared.dismiss()
    }

    func setScanning(_ on: Bool) {
        if on { startScanning() } else { stopScanning() }
    }

    // MARK: Target selection

    /// Enables "tap a detected target to click the app underneath".
    ///
    /// iOS has no public API to synthesise a touch into another window, so what
    /// actually happens is a hit-test hole: the overlay stops claiming touches
    /// inside every detected box, and the real touch falls through to whatever
    /// is beneath. A confirmation marker is drawn so the user can see which
    /// target was hit.
    func setTapToSelectEnabled(_ on: Bool) {
        tapToSelectEnabled = on
        if !on {
            lastTappedTarget = nil
            lastTappedAt = nil
        }
        OverlayManager.shared.setTapTargets(on ? tapTargetRects() : [])
    }

    /// Screen-space rects for the current detections, in window points.
    private func tapTargetRects() -> [CGRect] {
        guard let window = captureSourceWindow() else { return [] }
        _ = window
        return screenDetections.map { $0.rect }
    }

    /// Records which target was tapped, for the marker overlay.
    func noteTap(at point: CGPoint) {
        guard tapToSelectEnabled else { return }
        // Pick the smallest box containing the point, so an inner target wins
        // over an enclosing one.
        let hit = screenDetections
            .filter { $0.rect.insetBy(dx: -8, dy: -8).contains(point) }
            .min { ($0.rect.width * $0.rect.height) < ($1.rect.width * $1.rect.height) }
        lastTappedTarget = hit
        lastTappedAt = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Recomputes the holes after each scan while tap-to-select is on.
    private func refreshTapTargets() {
        guard tapToSelectEnabled else { return }
        OverlayManager.shared.setTapTargets(tapTargetRects())
    }

    func startScanning() {
        guard !scanning else { return }
        guard engine != nil else {
            lastError = "推理引擎未就绪"
            return
        }
        scanning = true
        lastError = nil
        framesScanned = 0
        schedule()
        // Honour the saved "tap target" preference from the moment scanning starts.
        if DetectorSettings.shared.overlayTapThrough {
            setTapToSelectEnabled(true)
        }
    }

    /// Starts scanning after making sure the chosen model is loaded.
    func startScanning(with model: ModelItem?) async {
        if let model {
            let ok = await prepareEngine(with: model)
            guard ok else {
                scanning = false
                return
            }
        }
        startScanning()
    }

    func stopScanning() {
        scanning = false
        timer?.invalidate()
        timer = nil
        screenDetections = []
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: max(0.1, interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Scan tick

    private func tick() {
        guard scanning, !inFlight else { return }
        guard let engine, let window = captureSourceWindow() else { return }
        // A window that is hidden or detached cannot be snapshotted.
        guard window.windowScene != nil, !window.isHidden,
              window.bounds.width > 1, window.bounds.height > 1 else { return }
        inFlight = true

        let size = window.bounds.size
        guard let image = snapshot(window: window, size: size) else {
            inFlight = false
            lastError = "无法截取屏幕内容"
            return
        }

        let t0 = Date()
        Task { @MainActor in
            let found = await engine.detectImage(image)
            // `detectImage` returns normalised coords; convert to screen points.
            self.screenDetections = found.map { d in
                var c = d
                c.rect = CGRect(x: d.rect.minX * size.width,
                                y: d.rect.minY * size.height,
                                width: d.rect.width * size.width,
                                height: d.rect.height * size.height)
                return c
            }
            self.lastScanMs = Date().timeIntervalSince(t0) * 1000
            self.framesScanned += 1
            // Feed the chat context with the normalised results (not the
            // screen-space copies, which are only for drawing).
            DetectionStore.shared.record(detections: found, source: "overlay")
            // Aim assist works from the same normalised results, so it needs no
            // separate capture pass.
            AimController.shared.ingest(detections: found, in: size)
            // Keep the tap-through holes aligned with the new boxes.
            self.refreshTapTargets()
            self.inFlight = false
        }
    }

    /// Snapshots a window's content.
    ///
    /// Uses `drawHierarchy(afterScreenUpdates:)` rather than
    /// `layer.render(in:)`: rendering a *live* layer tree into a foreign context
    /// is a known crash source (the render server may be mutating it
    /// concurrently), whereas `drawHierarchy` is the sanctioned snapshot path.
    /// Drawing a specific view's hierarchy also naturally excludes the overlay,
    /// which lives in its own window.
    private func snapshot(window: UIWindow, size: CGSize) -> UIImage? {
        let target = window.rootViewController?.view ?? window
        guard target.bounds.width > 1, target.bounds.height > 1 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1          // the model resizes to 640 anyway
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            target.drawHierarchy(in: CGRect(origin: .zero, size: size),
                                 afterScreenUpdates: false)
        }
    }

    /// Which window to scan.
    ///
    /// App-internal build: the app's own main window, rendered directly via
    /// `layer.render(in:)` so the overlay window itself is never included
    /// (that would recurse: we'd detect the boxes we just drew).
    ///
    /// Cross-process build: replace this with a system capture source. The
    /// rest of the pipeline needs no changes.
    private func captureSourceWindow() -> UIWindow? {
        if let w = sourceWindow { return w }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { !($0 is OverlayWindow) && $0.isKeyWindow }
    }

    private func render(window: UIWindow, size: CGSize, scale: CGFloat) -> UIImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            // Renders only this window's layer tree, so the overlay is excluded.
            window.layer.render(in: ctx.cgContext)
        }
    }

    // MARK: Cleanup

    func shutdown() {
        stopScanning()
        stopSystemOverlayMonitor()
    }
}
