import SwiftUI

// MARK: - Router
//
// The card key screen replaces the old PIN gate and is the only way in.
// The camera view still takes over full screen; everything browsable lives
// behind the floating tab bar.

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var overlay = OverlayState.shared
    @ObservedObject private var safeMode = SafeMode.shared
    @ObservedObject private var license = LicenseManager.shared

    @State private var tab: MainTab = .detect
    @State private var showPhoto = false
    @State private var showSettings = false
    @State private var showAim = false

    /// Optional updates the user has closed. Kept per launch: a new version
    /// appearing later must be able to raise the banner again.
    @State private var dismissedNotices: Set<String> = []

    var body: some View {
        ZStack {
            if safeMode.isEngaged {
                // The previous launch died before finishing; offer the log.
                RecoveryView().transition(.opacity)
            } else if !license.blockingNotices.isEmpty {
                // A forced update outranks everything else, including the login
                // screen: the card cannot be entered until the app is current.
                ForcedUpdateView(notices: license.blockingNotices)
                    .transition(.opacity)
            } else if !license.state.canUseApp {
                LoginView().transition(.opacity)
            } else if app.showCamera {
                CameraView().transition(.opacity)
            } else {
                MainTabView(tab: $tab).transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            // An advisory update is a closable banner, not a gate: the user keeps
            // working and decides when to install.
            if !safeMode.isEngaged,
               license.blockingNotices.isEmpty,
               let notice = advisoryNotice {
                UpdateNoticeBanner(notice: notice) {
                    withAnimation(DS.Motion.standard) {
                        _ = dismissedNotices.insert(notice.id)
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.top, DS.Space.s)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.standard, value: app.showCamera)
        .animation(DS.Motion.standard, value: license.state)
        .animation(DS.Motion.standard, value: advisoryNotice?.id)
        .task {
            // Cold-start intro. This runs before the licence check so the splash
            // covers the waiting, and the gate inside LaunchSplash is
            // process-wide, so the later call from DashboardView.onAppear turns
            // into a no-op rather than replaying it.
            LaunchSplash.presentIfNeeded()
            // Single bootstrap point: the manager starts its own heartbeat.
            await license.bootstrap()
        }
        .sheet(isPresented: $showPhoto) { PhotoDetectView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showAim) { AimSettingsView() }
        .onReceive(NotificationCenter.default.publisher(for: .openPhotoDetect)) { _ in
            showPhoto = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAimSettings)) { _ in
            showAim = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { _ in
            tab = .chat
        }
    }

    /// The first optional update the user has not closed yet.
    private var advisoryNotice: VersionNotice? {
        license.advisoryNotices.first { !dismissedNotices.contains($0.id) }
    }
}

enum MainTab: String, CaseIterable, Identifiable {
    case detect
    case chat
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .detect: return "检测"
        case .chat: return "聊天"
        case .profile: return "我的"
        }
    }

    var icon: String {
        switch self {
        case .detect: return "viewfinder"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .profile: return "person.crop.circle"
        }
    }

    var activeIcon: String {
        switch self {
        case .detect: return "viewfinder.circle.fill"
        case .chat: return "bubble.left.and.text.bubble.right.fill"
        case .profile: return "person.crop.circle.fill"
        }
    }
}

// MARK: - Tab container
//
// The bar floats above the content rather than sitting at the bottom edge, so
// the scroll view runs underneath and the glass has something to refract.

struct MainTabView: View {
    @Binding var tab: MainTab

    /// Height of the floating bar plus its margins.
    static let barFootprint: CGFloat = 76

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .detect:  DashboardView()
                case .chat:    ChatView()
                case .profile: ProfileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FloatingTabBar(tab: $tab)
                .padding(.horizontal, DS.Space.xl)
                .padding(.bottom, DS.Space.s)
        }
        .background(Palette.canvas.ignoresSafeArea())
    }
}

// MARK: - Floating tab bar

struct FloatingTabBar: View {
    @Binding var tab: MainTab

    @Namespace private var slabNamespace

    /// True when the real Liquid Glass material is in use. The selection colours
    /// differ: the glass surface is already near white, so a white slab on top
    /// of it would be invisible.
    private var onGlass: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases) { item in
                itemButton(item)
            }
        }
        .padding(5)
        .floatingGlass(cornerRadius: DS.Radius.pill, tint: Color.white.opacity(0.22))
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.40), lineWidth: 0.6)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func itemButton(_ item: MainTab) -> some View {
        let isActive = tab == item

        Button {
            guard !isActive else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(DS.Motion.spring) { tab = item }
        } label: {
            HStack(spacing: 6) {
                tabIcon(item, isActive: isActive)

                // The label appears only on the active item: a permanent label on
                // all three makes the bar too wide to read as a compact control.
                if isActive {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .fixedSize()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.85)),
                            removal: .opacity))
                }
            }
            .foregroundColor(isActive ? Palette.accent : Palette.inkSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .background {
                if isActive && !onGlass {
                    Capsule()
                        .fill(Palette.accentSoft)
                        .matchedGeometryEffect(id: "tabSlab", in: slabNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Tab glyph. `symbolEffect` is iOS 17; on 15 the glyph simply swaps, which
    /// is the same information without the bounce - the animation is decoration,
    /// the selection state is the function.
    @ViewBuilder
    private func tabIcon(_ item: MainTab, isActive: Bool) -> some View {
        let glyph = Image(systemName: isActive ? item.activeIcon : item.icon)
            .font(.system(size: 15, weight: isActive ? .semibold : .regular))

        if #available(iOS 17.0, *) {
            glyph.symbolEffect(.bounce, value: isActive)
        } else {
            glyph
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let openChat = Notification.Name("yolo.openChat")
}
