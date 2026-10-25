import SwiftUI
import UIKit

// MARK: - Overlay window
//
// A dedicated passthrough window floating above the app's content, styled after
// game "cheat menu" overlays.
//
// Touch handling: SwiftUI renders its whole hierarchy into one hosting view, so
// a class check on the hit view cannot tell "tap on the panel" from "tap on
// empty space". The window is instead told which rectangles are interactive and
// forwards touches only inside them; everything else falls through.
//
// A separate UIWindow is also what makes a cross-process build possible later:
// the same window can be hosted at a higher level once the app runs outside the
// sandbox. Today it floats within this app only.

final class OverlayWindow: UIWindow {
    /// Interactive regions in window (point) coordinates.
    var interactiveRects: [CGRect] = []

    /// Regions the window must NOT intercept, so the touch reaches the window
    /// below. Used for "tap a detected target to click the app underneath".
    var tapThroughRects: [CGRect] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // A tap-through hole wins over everything.
        if tapThroughRects.contains(where: { $0.contains(point) }) {
            if event != nil {
                Task { @MainActor in OverlayState.shared.noteTap(at: point) }
            }
            return nil
        }
        guard interactiveRects.contains(where: { $0.contains(point) }) else { return nil }
        return super.hitTest(point, with: event)
    }
}

// MARK: - Overlay manager

@MainActor
final class OverlayManager {
    static let shared = OverlayManager()

    private var window: OverlayWindow?
    private(set) var isPresented = false

    /// Window level used for the current mode.
    private var currentLevel: UIWindow.Level = .normal + 1

    /// Bumped on every present/dismiss. A deferred teardown captured an older
    /// generation and skips itself, so it can never destroy a window that was
    /// created after it was scheduled.
    ///
    /// Without this, switching mode tore the overlay down for good: `dismiss()`
    /// defers its work, `present()` then immediately builds a new window, and the
    /// pending teardown ran afterwards and set that new window to nil. The panel
    /// stayed on screen but had no window behind it, so nothing was touchable.
    private var generation = 0

    private init() {}

    /// Creates the window at `level`, or updates the level of the existing one.
    @discardableResult
    func present(level: UIWindow.Level? = nil) -> Bool {
        generation += 1
        let target = level ?? currentLevel

        // An existing window only needs its level adjusted. Rebuilding it here
        // would drop the hosting view's state for no benefit.
        if isPresented, let w = window {
            if w.windowLevel != target { w.windowLevel = target }
            currentLevel = target
            w.isHidden = false
            return true
        }

        guard let scene = activeScene() else { return false }

        let w = OverlayWindow(windowScene: scene)
        w.windowLevel = target
        currentLevel = target
        w.backgroundColor = .clear
        w.isOpaque = false
        w.rootViewController = UIHostingController(rootView: OverlayRootView())
        w.rootViewController?.view.backgroundColor = .clear
        w.isHidden = false

        window = w
        isPresented = true
        OverlayState.shared.sourceWindow = mainAppWindow(excluding: w)
        return true
    }

    /// Tears the overlay down after the current event has finished dispatching.
    ///
    /// Deferred because destroying the window that is mid-dispatch crashes in
    /// UIKit; guarded because a later `present()` must not be undone by it.
    func dismiss() {
        generation += 1
        let scheduled = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == scheduled else { return }
            self.window?.isHidden = true
            self.window?.interactiveRects = []
            self.window?.tapThroughRects = []
            self.window = nil
            self.isPresented = false
        }
    }

    func updateInteractiveRects(_ rects: [CGRect]) {
        window?.interactiveRects = rects
    }

    func setTapTargets(_ rects: [CGRect]) {
        window?.tapThroughRects = rects
    }

    private func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }

    private func mainAppWindow(excluding overlay: UIWindow) -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let key = scene.windows.first(where: { !($0 is OverlayWindow) && $0.isKeyWindow }) {
                return key
            }
        }
        return scenes.flatMap { $0.windows }.first { !($0 is OverlayWindow) }
    }
}

// MARK: - Root

@MainActor
struct OverlayRootView: View {
    @ObservedObject private var state = OverlayState.shared
    @ObservedObject private var aim = AimController.shared

    @State private var fabCenter: CGPoint = .zero
    @State private var dragOrigin: CGPoint? = nil
    @State private var didLayout = false

    private let fabSize: CGFloat = 54

    var body: some View {
        GeometryReader { geo in
            let layout = OverlayLayout(bounds: geo.size, fabCenter: fabCenter, fabSize: fabSize)

            ZStack(alignment: .topLeading) {
                // Launch-mode picker takes over the whole overlay: the mode
                // decides the window level and whether the kernel is touched, so
                // nothing else may run until it is committed.
                if state.showingLaunchPicker {
                    // A full-screen tap shield: while the picker is up nothing
                    // behind it may be interacted with, and a tap outside the
                    // card dismisses rather than falling through to the app.
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { state.cancelLaunchPicker() }

                    VStack {
                        Spacer(minLength: 0)
                        LaunchModePicker(onConfirm: { mode in
                            state.commitLaunchMode(mode)
                        }, onCancel: {
                            state.cancelLaunchPicker()
                        })
                        .frame(maxWidth: min(360, geo.size.width - 24))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    overlayContent(geo: geo, layout: layout)
                }
            }
            .onAppear { syncLayout(geo.size, layout) }
            .onChangeCompat(of: geo.size) { _, _ in syncLayout(geo.size, layout) }
            .onChangeCompat(of: state.menuExpanded) { _, _ in syncLayout(geo.size, layout) }
            .onChangeCompat(of: state.showingLaunchPicker) { _, _ in syncLayout(geo.size, layout) }
            .onChangeCompat(of: fabCenter) { _, _ in syncLayout(geo.size, layout) }
        }
        .ignoresSafeArea()
    }

    /// The normal overlay: detection boxes, the aim overlay, the panel, the FAB.
    @ViewBuilder
    private func overlayContent(geo: GeometryProxy, layout: OverlayLayout) -> some View {
        ZStack(alignment: .topLeading) {
            if state.drawOnScreen && state.scanning {
                BoxLayer(detections: state.screenDetections,
                         selected: state.lastTappedTarget)
                    .allowsHitTesting(false)
            }

            // Aim overlay: the target box, the aim point, and the current
            // cursor position with a line to the target, so tuning is visual.
            if aim.settings.isEnabled {
                AimOverlay()
                    .allowsHitTesting(false)
            }

            if state.menuExpanded {
                CheatPanel()
                    .frame(width: layout.panelRect.width,
                           height: layout.panelRect.height)
                    .position(x: layout.panelRect.midX, y: layout.panelRect.midY)
                    .transition(.opacity)
            }

            FloatingButton(expanded: state.menuExpanded,
                           scanning: state.scanning)
                .frame(width: fabSize, height: fabSize)
                .position(x: layout.fabRect.midX, y: layout.fabRect.midY)
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    state.toggleMenu()
                }
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            if dragOrigin == nil { dragOrigin = fabCenter }
                            guard let start = dragOrigin else { return }
                            fabCenter = layout.clamp(CGPoint(
                                x: start.x + value.translation.width,
                                y: start.y + value.translation.height))
                        }
                        .onEnded { _ in dragOrigin = nil }
                )
        }
    }

    private func syncLayout(_ size: CGSize, _ layout: OverlayLayout) {
        if !didLayout {
            didLayout = true
            fabCenter = layout.defaultFabCenter
        }

        // The hit-test gate is an allowlist of rectangles, so every visible
        // control must be registered or it renders but never receives a touch.
        //
        // The launch-mode picker covers the whole screen, which is exactly the
        // case that was missing: it is shown instead of `overlayContent`, so
        // nothing registered a rect and every tap fell through to `nil`.
        if state.showingLaunchPicker {
            OverlayManager.shared.updateInteractiveRects([CGRect(origin: .zero, size: size)])
            return
        }

        var rects = [layout.fabRect]
        if state.menuExpanded { rects.append(layout.panelRect) }
        OverlayManager.shared.updateInteractiveRects(rects)
    }
}

// MARK: - Geometry

struct OverlayLayout {
    let bounds: CGSize
    let fabSize: CGFloat
    let fabCenterPoint: CGPoint

    init(bounds: CGSize, fabCenter: CGPoint, fabSize: CGFloat) {
        self.bounds = bounds
        self.fabSize = fabSize
        let fallback = CGPoint(x: max(bounds.width - 47, 47), y: 140)
        self.fabCenterPoint = fabCenter == .zero ? fallback : fabCenter
    }

    var defaultFabCenter: CGPoint { CGPoint(x: max(bounds.width - 47, 47), y: 140) }

    var fabRect: CGRect {
        CGRect(x: fabCenterPoint.x - fabSize / 2,
               y: fabCenterPoint.y - fabSize / 2,
               width: fabSize, height: fabSize)
    }

    var panelRect: CGRect {
        let w = min(316, max(bounds.width - 24, 250))
        let h = min(486, max(bounds.height - 140, 280))
        let x = fabCenterPoint.x > bounds.width / 2 ? (bounds.width - w - 12) : 12
        let below = fabCenterPoint.y + fabSize / 2 + 10
        let top = (below + h <= bounds.height - 12)
            ? below
            : max(12, fabCenterPoint.y - fabSize / 2 - 10 - h)
        return CGRect(x: max(8, x),
                      y: min(max(12, top), max(12, bounds.height - h - 12)),
                      width: w, height: h)
    }

    func clamp(_ p: CGPoint) -> CGPoint {
        let half = fabSize / 2
        let minX = half + 6
        let maxX = max(minX, bounds.width - half - 6)
        let minY = half + 60
        let maxY = max(minY, bounds.height - half - 40)
        return CGPoint(x: min(max(minX, p.x), maxX), y: min(max(minY, p.y), maxY))
    }
}

// MARK: - Floating button
// Purely visual; the parent attaches tap and drag so the two never conflict.

struct FloatingButton: View {
    let expanded: Bool
    let scanning: Bool

    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(white: 0.09).opacity(0.94))
                .overlay(
                    Circle().stroke(scanning ? CheatPalette.accent : Color.white.opacity(0.22),
                                    lineWidth: scanning ? 2 : 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)

            if scanning {
                Circle()
                    .stroke(CheatPalette.accent.opacity(0.55), lineWidth: 2)
                    .scaleEffect(pulse ? 1.5 : 1.0)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false),
                               value: pulse)
                    .onAppear { pulse = true }
            }

            Image(systemName: expanded ? "xmark" : "gamecontroller.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(scanning ? CheatPalette.accent : .white)
        }
        .contentShape(Circle())
    }
}

// MARK: - Palette

enum CheatPalette {
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.96)
    static let surface = Color(white: 1.0).opacity(0.06)
    static let surfaceStrong = Color(white: 1.0).opacity(0.10)
    static let border = Color(white: 1.0).opacity(0.10)
    static let accent = Color(red: 0.20, green: 0.95, blue: 0.55)
    static let accentDim = Color(red: 0.20, green: 0.95, blue: 0.55).opacity(0.15)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let warnDim = Color(red: 1.0, green: 0.72, blue: 0.20).opacity(0.15)
    static let danger = Color(red: 1.0, green: 0.35, blue: 0.35)
    static let dangerDim = Color(red: 1.0, green: 0.35, blue: 0.35).opacity(0.15)
    static let text = Color.white
    static let textDim = Color.white.opacity(0.55)
}

// MARK: - Panel pages

enum CheatPage: String, CaseIterable, Identifiable {
    case main
    case model
    case scan
    case tuning
    case system
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .main: return "主菜单"
        case .model: return "模型"
        case .scan: return "扫描"
        case .tuning: return "调参"
        case .system: return "系统"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .main: return "square.grid.2x2"
        case .model: return "cube.box"
        case .scan: return "viewfinder"
        case .tuning: return "slider.horizontal.3"
        case .system: return "square.stack.3d.up"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Panel
//
// Structured as a category menu: a persistent header, a tab strip, and one page
// at a time. This replaces the earlier single long scroll, where every control
// was visible at once and the panel was hard to scan.

@MainActor
struct CheatPanel: View {
    @ObservedObject private var state = OverlayState.shared
    @ObservedObject private var settings = DetectorSettings.shared
    @ObservedObject private var manager = LlamaModelManager.shared
    @ObservedObject private var aim = AimController.shared
    @ObservedObject private var kernel = KernelExploitRunner.shared

    @State private var page: CheatPage = .main

    var body: some View {
        VStack(spacing: 0) {
            header
            tabStrip
            divider

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    switch page {
                    case .main:      mainPage
                    case .model:     modelPage
                    case .scan:      scanPage
                    case .tuning:    tuningPage
                    case .system:    systemPage
                    case .settings:  settingsPage
                    }
                    creditBlock
                }
                .padding(12)
            }
        }
        .background(
            ZStack {
                // Dark glass: blur plus a gradient so the panel reads as a lit
                // pane over the content behind it rather than a flat rectangle.
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(CheatPalette.bg)
                LinearGradient(
                    colors: [Color.white.opacity(0.06),
                             Color.clear,
                             Color.black.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22),
                                 Color.white.opacity(0.06),
                                 Color.white.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 26, y: 12)
        .colorScheme(.dark)
    }

    private var divider: some View {
        Rectangle()
            .fill(CheatPalette.border)
            .frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.scanning ? CheatPalette.accent : CheatPalette.warn)
                .frame(width: 7, height: 7)
            Text("YOLO MENU")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundColor(CheatPalette.text)
                .letterSpacing(1.1)

            Text(AppBrand.channel)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(CheatPalette.accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(CheatPalette.accentDim)
                )

            Spacer(minLength: 0)

            Text(state.scanning ? "LIVE" : "IDLE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(state.scanning ? CheatPalette.accent : CheatPalette.textDim)

            Button {
                state.hideOverlay()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(CheatPalette.textDim)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(CheatPalette.surface))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: Tabs

    @Namespace private var tabStripNamespace

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(CheatPage.allCases) { p in
                    let isActive = page == p
                    Button {
                        guard !isActive else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            page = p
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: p.icon)
                                .font(.system(size: 9, weight: .bold))
                            Text(p.title)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(isActive ? .black : CheatPalette.textDim)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background {
                            if isActive {
                                // Sliding slab, matched across pages.
                                Capsule()
                                    .fill(CheatPalette.accent)
                                    .matchedGeometryEffect(id: "pageSlab",
                                                           in: tabStripNamespace)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    // MARK: Main

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            masterSwitch

            CheatSection(title: "STATUS") {
                VStack(spacing: 4) {
                    CheatStat(k: "扫描帧", v: "\(state.framesScanned)")
                    CheatStat(k: "目标", v: "\(state.screenDetections.count)")
                    CheatStat(k: "耗时", v: String(format: "%.0fms", state.lastScanMs))
                    CheatStat(k: "检测模型", v: detectModelName)
                    CheatStat(k: "对话模型", v: manager.tier.title)
                }
            }

            CheatSection(title: "快速操作") {
                VStack(spacing: 6) {
                    // Gated: the guard reports the reason through the panel's
                    // error line instead of failing silently.
                    CheatButton(title: "Aim 辅助",
                                value: aim.settings.isEnabled ? "ON" : "OFF",
                                icon: "scope",
                                highlight: aim.settings.isEnabled) {
                        guard FeatureGateCheck.allow("aim_assist") else {
                            state.lastError = LicenseManager.shared.gateReason("aim_assist")
                            return
                        }
                        if aim.settings.isEnabled { aim.stop() } else { aim.start() }
                    }
                    CheatButton(title: "全屏画框", value: state.drawOnScreen ? "ON" : "OFF",
                                icon: "square.dashed", highlight: state.drawOnScreen) {
                        state.drawOnScreen.toggle()
                    }
                    CheatButton(title: "图片识别", icon: "photo") {
                        guard FeatureGateCheck.allow("photo_detect") else {
                            state.lastError = LicenseManager.shared.gateReason("photo_detect")
                            return
                        }
                        NotificationCenter.default.post(name: .openPhotoDetect, object: nil)
                        state.menuExpanded = false
                    }
                    CheatButton(title: "检测调参", icon: "slider.horizontal.3") {
                        NotificationCenter.default.post(name: .openSettings, object: nil)
                        state.menuExpanded = false
                    }
                }
            }

            CheatSection(title: "AIM") {
                VStack(spacing: 4) {
                    CheatStat(k: "目标", v: aim.targetBox == nil ? "无" : "已锁定")
                    CheatStat(k: "误差", v: String(format: "%.4f", aim.errorDistance))
                    CheatStat(k: "方式", v: aim.settings.transport.title)
                }
                .padding(.bottom, 4)
                CheatButton(title: "AIM 参数", icon: "slider.horizontal.3") {
                    NotificationCenter.default.post(name: .openAimSettings, object: nil)
                    state.menuExpanded = false
                }
            }

            CheatSection(title: "导航") {
                VStack(spacing: 6) {
                    CheatButton(title: "模型管理", icon: "cube.box") { page = .model }
                    CheatButton(title: "扫描设置", icon: "viewfinder") { page = .scan }
                    CheatButton(title: "识别调参", icon: "slider.horizontal.3") { page = .tuning }
                    CheatButton(title: "偏好设置", icon: "gearshape") { page = .settings }
                }
            }
        }
    }

    // MARK: Master switch

    private var masterSwitch: some View {
        Button {
            if state.scanning {
                state.stopScanning()
            } else {
                Task {
                    await state.startScanning(with: state.selectedModel)
                    if !state.scanning { state.menuExpanded = true }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: state.scanning ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.scanning ? "停止扫描" : "开始扫描")
                        .font(.system(size: 15, weight: .bold))
                    Text("持续识别屏幕内容")
                        .font(.system(size: 10))
                        .foregroundColor(CheatPalette.textDim)
                }
                Spacer(minLength: 0)
                Text(state.scanning ? "ON" : "OFF")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundColor(state.scanning ? CheatPalette.accent : CheatPalette.textDim)
            }
            .foregroundColor(CheatPalette.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(state.scanning ? CheatPalette.accentDim : CheatPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(state.scanning ? CheatPalette.accent.opacity(0.5) : CheatPalette.border,
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Model

    private var modelPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            CheatSection(title: "视觉模型") {
                if state.models.isEmpty {
                    Text("未发现模型")
                        .font(.system(size: 11))
                        .foregroundColor(CheatPalette.warn)
                } else {
                    VStack(spacing: 5) {
                        ForEach(state.models.prefix(4)) { item in
                            CheatRadio(label: item.name,
                                       detail: item.tier.label,
                                       selected: state.selectedModelID == item.id) {
                                state.selectModel(item)
                                Task {
                                    let wasScanning = state.scanning
                                    state.stopScanning()
                                    if wasScanning {
                                        await state.startScanning(with: item)
                                    } else {
                                        _ = await state.prepareEngine(with: item)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            CheatSection(title: "对话模型") {
                VStack(spacing: 5) {
                    ForEach(LlamaTier.allCases) { tier in
                        let spec = ModelCatalog.spec(for: tier)
                        CheatRadio(label: "\(tier.title) · \(spec.displayName)",
                                   detail: "\(spec.sizeText)\(spec.isDownloaded ? " · 已下载" : "")\(ModelCatalog.isSupported(tier) ? "" : " · 内存不足")",
                                   selected: manager.tier == tier) {
                            Task { await manager.select(tier: tier) }
                        }
                    }
                }
            }

            CheatSection(title: "下载状态") {
                VStack(spacing: 4) {
                    CheatStat(k: "状态", v: manager.state.label)
                    CheatStat(k: "进度", v: manager.downloadProgressText)
                    CheatStat(k: "速度", v: manager.downloadSpeedText)
                    CheatStat(k: "剩余", v: manager.downloadETAText)
                    if !manager.downloadMirror.isEmpty {
                        CheatStat(k: "来源", v: manager.downloadMirror)
                    }
                    if manager.downloadProgress > 0, manager.downloadProgress < 1 {
                        ProgressView(value: manager.downloadProgress)
                            .tint(CheatPalette.accent)
                            .padding(.top, 4)
                    }
                }
            }

            CheatSection(title: "操作") {
                VStack(spacing: 6) {
                    if manager.state == .downloading {
                        CheatButton(title: "暂停下载", icon: "pause.fill",
                                    highlight: true) { manager.pauseDownload() }
                    } else if !manager.spec.isDownloaded && manager.hasPartialDownload {
                        CheatButton(title: "继续下载（断点续传）", icon: "arrow.down.circle",
                                    highlight: true) { manager.resumeDownload() }
                    } else if !manager.spec.isDownloaded {
                        CheatButton(title: "开始下载 \(manager.spec.sizeText)",
                                    icon: "arrow.down.circle", highlight: true) { manager.download() }
                    }

                    if manager.spec.isDownloaded {
                        CheatButton(title: manager.state == .ready ? "重新加载" : "加载到内存",
                                    icon: "bolt.fill", highlight: true) {
                            Task { await manager.ensureLoaded() }
                        }
                        CheatButton(title: "从内存卸载", icon: "eject") {
                            Task { await manager.unload() }
                        }
                    }
                }
            }
        }
    }

    // MARK: Scan

    private var scanPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            CheatSection(title: "节奏") {
                CheatSlider(label: "扫描间隔",
                            value: $state.interval,
                            range: 0.2...2.0,
                            step: 0.1,
                            display: String(format: "%.1fs", state.interval))
            }
            .onChangeCompat(of: state.interval) { _, _ in
                if state.scanning {
                    state.stopScanning()
                    state.startScanning()
                }
            }

            CheatSection(title: "显示") {
                VStack(spacing: 8) {
                    CheatToggle(label: "全屏画框", isOn: $state.drawOnScreen)
                    CheatToggle(label: "框标签", isOn: $settings.showDebug)
                }
            }

            CheatSection(title: "启动方式") {
                VStack(spacing: 5) {
                    if let active = LaunchModeStore.shared.active {
                        CheatRadio(label: active.title,
                                   detail: active.subtitle,
                                   selected: true) {
                            // Re-open the picker without tearing the window down.
                            state.showingLaunchPicker = true
                        }
                    }

                    HStack(spacing: 4) {
                        Image(systemName: KernelSupport.isElevated
                              ? "checkmark.shield.fill" : "shield.slash.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(KernelSupport.isElevated
                                             ? CheatPalette.accent : CheatPalette.warn)
                        Text(KernelSupport.isElevated ? "未沙盒" : "沙盒环境")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(CheatPalette.textDim)
                        Text("·")
                            .foregroundColor(CheatPalette.textDim)
                        Text("iOS \(KernelSupport.currentVersionFull)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(CheatPalette.textDim)
                        Spacer(minLength: 0)
                    }

                    Text("点上方可重新选择启动方式（巨魔 / 自签）。")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(CheatPalette.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            CheatSection(title: "内核层") {
                VStack(spacing: 4) {
                    CheatStat(k: "状态", v: kernel.state.label,
                              tint: kernel.state.isBlocked ? CheatPalette.warn : CheatPalette.text)
                    CheatStat(k: "系统", v: "iOS \(KernelSupport.currentVersionFull)")
                    CheatStat(k: "上限", v: "16.6.1")
                    CheatStat(k: "提权", v: KernelSupport.isElevated ? "是" : "否")

                    if !kernel.log.isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(kernel.log.suffix(6), id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(CheatPalette.textDim)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(CheatPalette.surface)
                        )
                    }
                }
                .padding(.bottom, 4)

                CheatButton(title: "初始化内核",
                            icon: "bolt.shield",
                            highlight: kernel.isAvailable) {
                    guard FeatureGateCheck.allow("kernel_layer") else {
                        state.lastError = LicenseManager.shared.gateReason("kernel_layer")
                        return
                    }
                    kernel.run()
                }
            }

            CheatSection(title: "AIM 辅助") {
                VStack(spacing: 8) {
                    CheatToggle(label: "启用 Aim", isOn: Binding(
                        get: { aim.settings.isEnabled },
                        set: { want in
                            guard want else { aim.stop(); return }
                            guard FeatureGateCheck.allow("aim_assist") else {
                                state.lastError = LicenseManager.shared.gateReason("aim_assist")
                                return
                            }
                            aim.start()
                        }
                    ))

                    if aim.settings.isEnabled {
                        // Read-only. These numbers belong to the server now: it
                        // samples a fresh equivalent table on every heartbeat,
                        // so a slider here would be overwritten within a minute
                        // and would only mislead. The panel shows the live values
                        // plus the time left on them.
                        CheatStat(k: "头部偏移",
                                  v: aim.params.map {
                                      String(format: "%.2f / %.2f",
                                             $0.displayHeadOffset.y,
                                             $0.displayHeadOffset.x)
                                  } ?? "—")
                        CheatStat(k: "平滑系数",
                                  v: aim.params.map {
                                      String(format: "%.2f", $0.displaySmoothing)
                                  } ?? "—")
                        CheatStat(k: "剩余有效期",
                                  v: aim.params.map {
                                      String(format: "%.0f 秒", $0.remaining)
                                  } ?? "0 秒",
                                  tint: aim.paramsIsLive ? CheatPalette.accent : CheatPalette.warn)

                        CheatButton(title: "全部参数", icon: "slider.horizontal.3") {
                            NotificationCenter.default.post(name: .openAimSettings, object: nil)
                            state.menuExpanded = false
                        }
                    } else {
                        Text("瞄准检测框的头部中心，参数（头部偏移 / 平滑 / 速度 / 预判）全部由服务端下发。\n没有服务端参数就不会移动。")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(CheatPalette.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: Tuning

    private var tuningPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            CheatSection(title: "置信度") {
                VStack(spacing: 8) {
                    CheatSlider(label: "阈值",
                                value: $settings.confidence,
                                range: 0.1...0.9,
                                step: 0.01,
                                display: String(format: "%.2f", settings.confidence))
                    HStack(spacing: 5) {
                        CheatChip(text: "宽松", selected: settings.confidence <= 0.35) {
                            settings.confidence = 0.30
                        }
                        CheatChip(text: "标准", selected: abs(settings.confidence - 0.45) < 0.01) {
                            settings.confidence = 0.45
                        }
                        CheatChip(text: "严格", selected: settings.confidence >= 0.55) {
                            settings.confidence = 0.60
                        }
                    }
                }
            }

            CheatSection(title: "过滤") {
                VStack(spacing: 8) {
                    CheatSlider(label: "最小尺寸",
                                value: $settings.minSize,
                                range: 0.0...0.25,
                                step: 0.005,
                                display: String(format: "%.0f%%", settings.minSize * 100))
                    CheatSlider(label: "确认帧数",
                                value: Binding(get: { Double(settings.requiredFrames) },
                                               set: { settings.requiredFrames = Int($0.rounded()) }),
                                range: 1...10,
                                step: 1,
                                display: "\(settings.requiredFrames)")
                    CheatSlider(label: "合并 IoU",
                                value: $settings.nmsIoU,
                                range: 0.2...0.8,
                                step: 0.01,
                                display: String(format: "%.2f", settings.nmsIoU))
                }
            }

            CheatSection(title: "类别") {
                VStack(spacing: 8) {
                    CheatToggle(label: "只检测人", isOn: $settings.personOnly)
                    CheatToggle(label: "时序跟踪", isOn: $settings.trackingEnabled)
                }
            }

            CheatSection(title: "性能") {
                VStack(spacing: 8) {
                    CheatSlider(label: "最大帧率",
                                value: $settings.maxFPS,
                                range: 0.0...60.0,
                                step: 1.0,
                                display: settings.maxFPS <= 0 ? "不限" : "\(Int(settings.maxFPS))")
                    HStack(spacing: 5) {
                        CheatChip(text: "不限", selected: settings.maxFPS <= 0) { settings.maxFPS = 0 }
                        CheatChip(text: "30", selected: settings.maxFPS == 30) { settings.maxFPS = 30 }
                        CheatChip(text: "15", selected: settings.maxFPS == 15) { settings.maxFPS = 15 }
                    }
                }
            }

            CheatSection(title: "") {
                CheatButton(title: "恢复默认", icon: "arrow.counterclockwise") {
                    settings.resetToDefaults()
                }
            }
        }
    }

    // MARK: Settings

    /// 系统级悬浮组件（deb 注入 SpringBoard 的那份）。面板自己处理能力判断，
    /// 未越狱时显示为不可用卡片而不是一堆点了没反应的开关。
    private var systemPage: some View {
        SystemOverlayPage()
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            CheatSection(title: "行为") {
                VStack(spacing: 8) {
                    CheatToggle(label: "点击框看详情", isOn: $settings.boxTapDetails)
                    CheatToggle(label: "点击目标默认开", isOn: $settings.overlayTapThrough)
                    CheatToggle(label: "进后台卸载模型", isOn: $manager.autoUnloadOnBackground)
                }
            }

            CheatSection(title: "界面") {
                VStack(spacing: 6) {
                    CheatButton(title: "关闭悬浮窗", icon: "xmark.circle") {
                        state.hideOverlay()
                    }
                }
            }

            CheatSection(title: "关于") {
                VStack(spacing: 4) {
                    CheatStat(k: "版本", v: AppBrand.buildVersion)
                    CheatStat(k: "通道", v: AppBrand.channel)
                    CheatStat(k: "作者", v: AppBrand.author)
                    CheatStat(k: "联系", v: AppBrand.contact)
                    CheatStat(k: "设备内存", v: String(format: "%.0f GB", ModelCatalog.physicalMemoryGB))
                }
            }
        }
    }

    // MARK: Credit

    private var creditBlock: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "seal.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(AppBrand.fullNotice)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundColor(CheatPalette.accent)

            Text("by \(AppBrand.author) · \(AppBrand.contact)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(CheatPalette.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CheatPalette.accentDim)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CheatPalette.accent.opacity(0.35), lineWidth: 1)
        )
    }

    private var detectModelName: String {
        guard let m = state.selectedModel else { return "—" }
        return m.name.replacingOccurrences(of: ".mlmodelc", with: "")
    }
}

// MARK: - Primitives

struct CheatSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(CheatPalette.textDim)
                    .letterSpacing(0.9)
            }
            content()
        }
    }
}

struct CheatRadio: View {
    let label: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(selected ? CheatPalette.accent : CheatPalette.border, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    if selected {
                        Circle().fill(CheatPalette.accent).frame(width: 7, height: 7)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(label)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(CheatPalette.text)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundColor(CheatPalette.textDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? CheatPalette.accentDim : CheatPalette.surface)
            )
        }
        .buttonStyle(.plain)
    }
}

struct CheatSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(CheatPalette.textDim)
                Spacer()
                Text(display)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(CheatPalette.accent)
            }
            Slider(value: $value, in: range, step: step)
                .tint(CheatPalette.accent)
                .scaleEffect(x: 1, y: 0.85, anchor: .center)
        }
    }
}

struct CheatToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(CheatPalette.textDim)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(CheatPalette.accent)
                .scaleEffect(0.78)
        }
        .frame(height: 20)
    }
}

struct CheatButton: View {
    let title: String
    var value: String? = nil
    var icon: String? = nil
    var highlight: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                Spacer(minLength: 0)
                if let value {
                    Text(value)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(highlight ? CheatPalette.accent : CheatPalette.textDim)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundColor(CheatPalette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(highlight ? CheatPalette.accentDim : CheatPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(highlight ? CheatPalette.accent.opacity(0.4) : CheatPalette.border,
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct CheatChip: View {
    let text: String
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(selected ? .black : CheatPalette.textDim)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? CheatPalette.accent : CheatPalette.surface)
                )
        }
        .buttonStyle(.plain)
    }
}

struct CheatStat: View {
    let k: String
    let v: String
    var tint: Color = CheatPalette.text

    var body: some View {
        HStack {
            Text(k)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(CheatPalette.textDim)
            Spacer(minLength: 4)
            Text(v)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(tint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Aim overlay

/// Draws the aim point, the cursor, and the error between them.
struct AimOverlay: View {
    @ObservedObject private var aim = AimController.shared

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                // The head band comes from the server's table, so it is drawn
                // only when a live table exists. `nil` here means "no parameters",
                // and drawing a guessed band would misreport the aim point.
                if let box = aim.targetBox, let bandFraction = aim.headBandFraction {
                    let bandHeight = box.height * CGFloat(bandFraction)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(CheatPalette.warn, lineWidth: 1)
                        .frame(width: box.width, height: max(bandHeight, 2))
                        .offset(x: box.minX, y: box.minY)
                }

                if let target = aim.aimPoint {
                    // Line from cursor to target.
                    Path { p in
                        p.move(to: CGPoint(x: aim.cursor.x * w, y: aim.cursor.y * h))
                        p.addLine(to: CGPoint(x: target.x * w, y: target.y * h))
                    }
                    .stroke(CheatPalette.warn.opacity(0.6),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    // Target reticle.
                    Circle()
                        .stroke(CheatPalette.warn, lineWidth: 2)
                        .frame(width: 20, height: 20)
                        .position(x: target.x * w, y: target.y * h)
                }

                // Cursor, so the movement is visible while tuning.
                Circle()
                    .fill(CheatPalette.accent)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .position(x: aim.cursor.x * w, y: aim.cursor.y * h)
            }
        }
    }
}

// MARK: - Box layer

struct BoxLayer: View {
    let detections: [Detection]
    var selected: Detection? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(detections) { d in
                let isSelected = selected?.id == d.id
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? CheatPalette.warn
                                           : (d.label == "person" ? CheatPalette.accent : Color.cyan),
                                lineWidth: isSelected ? 3 : 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill((isSelected ? CheatPalette.warn
                                      : (d.label == "person" ? CheatPalette.accent : Color.cyan))
                                        .opacity(isSelected ? 0.22 : 0.12))
                        )
                    Text("\(d.label) \(Int(d.confidence * 100))%")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(isSelected
                                                   ? CheatPalette.warn
                                                   : (d.label == "person"
                                                      ? CheatPalette.accent : Color.cyan)))
                        .offset(y: -16)
                }
                .frame(width: max(d.rect.width, 2), height: max(d.rect.height, 2))
                .offset(x: d.rect.minX, y: d.rect.minY)
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let openPhotoDetect = Notification.Name("yolo.openPhotoDetect")
    static let openSettings = Notification.Name("yolo.openSettings")
    static let openAimSettings = Notification.Name("yolo.openAimSettings")
}
