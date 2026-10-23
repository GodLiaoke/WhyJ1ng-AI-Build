import SwiftUI
import UIKit

// MARK: - Launch animation
//
// One 2 s intro, played once per cold launch, over the whole screen.
//
// Two deliberate decisions:
//
// 1. It runs in its own `UIWindow`, not as an overlay inside a view hierarchy.
//    A SwiftUI overlay attached from the dashboard would sit below the floating
//    tab bar, and the bar would show through the splash. A window at
//    `.alert + 100` covers everything without touching `RootView`.
//
// 2. It can never trap the app. The view ends itself, `LaunchSplash` arms a hard
//    teardown at 2.8 s as a second net, a tap anywhere ends it immediately, and
//    a missing window scene just skips it. Nothing here is on the boot path:
//    `LicenseManager.bootstrap()` runs in parallel and is never awaited.
//
// Everything is native SwiftUI. No third-party dependency, and nothing above
// what iOS 15 provides.

// MARK: - Splash view

/// The animation itself. `LaunchSplash` hosts it in its own window; that is the
/// entry point callers should use, because a bare `LaunchAnimationView()` mounted
/// as an overlay has nobody to take it down when the sequence ends.
struct LaunchAnimationView: View {

    /// Called exactly once, whichever way the animation ends. `@MainActor` so the
    /// view can hand off from its own timeline task without assuming anything
    /// about the caller.
    var onFinish: @MainActor () -> Void

    @State private var markIn = false
    @State private var haloIn = false
    @State private var sweep = false
    @State private var wordIn = false
    @State private var taglineIn = false
    @State private var progress: CGFloat = 0
    @State private var hintIn = false
    @State private var visible = true

    /// Explicit, because the private `@State` properties would otherwise make
    /// the synthesised memberwise initialiser private and no other file could
    /// reach this type.
    init(onFinish: @MainActor @escaping () -> Void = {}) {
        self.onFinish = onFinish
    }

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: DS.Space.l) {
                mark
                wordmark
            }
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 1.05)

            footer

            // Tap anywhere to skip. The transparent layer keeps the gesture
            // alive over the whole screen instead of only over the content.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { finish() }
        }
        .onAppear(perform: run)
    }

    // MARK: Layers

    private var backdrop: some View {
        ZStack {
            Palette.surface
            RadialGradient(gradient: Gradient(colors: [LaunchTint.glow.opacity(0.13),
                                                       Color.clear]),
                           center: .center,
                           startRadius: 8,
                           endRadius: 320)
            RadialGradient(gradient: Gradient(colors: [LaunchTint.glow.opacity(0.06),
                                                       Color.clear]),
                           center: .init(x: 0.5, y: 0.92),
                           startRadius: 4,
                           endRadius: 260)
        }
        .ignoresSafeArea()
    }

    /// Squircle badge with a scan line sweeping across it: the app's subject is
    /// finding things in a frame, so the intro shows exactly that.
    private var mark: some View {
        ZStack {
            Circle()
                .stroke(LaunchTint.glow.opacity(0.20), lineWidth: 1)
                .frame(width: 118, height: 118)
                .scaleEffect(haloIn ? 1.55 : 0.55)
                .opacity(haloIn ? 0 : 1)

            Circle()
                .fill(LaunchTint.glow.opacity(haloIn ? 0.10 : 0.02))
                .frame(width: 118, height: 118)
                .scaleEffect(haloIn ? 1.0 : 0.5)

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(gradient: Gradient(colors: [LaunchTint.glow,
                                                               LaunchTint.deep]),
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
                .frame(width: 88, height: 88)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .overlay(
                    Image(systemName: "viewfinder")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(.white.opacity(0.96))
                )
                .overlay(scanLine)
                .shadow(color: LaunchTint.glow.opacity(0.32), radius: 22, x: 0, y: 10)
                .scaleEffect(markIn ? 1 : 0.74)
                .opacity(markIn ? 1 : 0)
        }
        .frame(height: 130)
    }

    private var scanLine: some View {
        GeometryReader { geo in
            LinearGradient(gradient: Gradient(colors: [Color.white.opacity(0),
                                                       Color.white.opacity(0.9),
                                                       Color.white.opacity(0)]),
                           startPoint: .leading,
                           endPoint: .trailing)
                .frame(height: 1.6)
                .offset(y: sweep ? geo.size.height * 0.82 : geo.size.height * 0.14)
        }
        .mask(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .allowsHitTesting(false)
    }

    /// Characters appear one after another. No `.tracking` here on purpose:
    /// that modifier is iOS 16+, and this target still has to build for 15.
    private var wordmark: some View {
        VStack(spacing: DS.Space.s) {
            HStack(spacing: 0) {
                ForEach(Array(AppBrand.name.enumerated()), id: \.offset) { idx, ch in
                    if ch == " " {
                        Color.clear.frame(width: 7, height: 1)
                    } else {
                        Text(String(ch))
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .foregroundColor(Palette.ink)
                            .opacity(wordIn ? 1 : 0)
                            .offset(y: wordIn ? 0 : 9)
                            .animation(.easeOut(duration: 0.42).delay(Double(idx) * 0.028),
                                       value: wordIn)
                    }
                }
            }

            Text(AppBrand.tagline)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(Palette.inkTertiary)
                .opacity(taglineIn ? 1 : 0)
                .offset(y: taglineIn ? 0 : 5)
        }
    }

    private var footer: some View {
        VStack(spacing: DS.Space.m) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.separator)
                    .frame(width: 132, height: 2)
                Capsule()
                    .fill(LinearGradient(gradient: Gradient(colors: [LaunchTint.glow,
                                                                     LaunchTint.deep]),
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(width: 132 * progress, height: 2)
            }

            Text("点击任意处跳过")
                .font(.system(size: 11))
                .foregroundColor(Palette.inkTertiary)
                .opacity(hintIn ? 1 : 0)
        }
        .padding(.bottom, 46)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: Timeline

    /// Runs the whole sequence. Wrapped in a single task so every step is
    /// cancelled together if the view goes away mid-flight.
    private func run() {
        Task { @MainActor in
            withAnimation(.spring(response: 0.52, dampingFraction: 0.78)) {
                markIn = true
            }
            withAnimation(.easeOut(duration: 0.85)) {
                haloIn = true
            }
            withAnimation(.easeInOut(duration: 0.55)) {
                progress = 0.45
            }

            try? await Task.sleep(nanoseconds: 210_000_000)
            withAnimation(.easeInOut(duration: 0.62)) {
                wordIn = true
            }

            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.easeOut(duration: 0.45)) {
                taglineIn = true
            }
            // Two passes, down and back: enough to read as a scan, short enough
            // to finish inside the window.
            withAnimation(.easeInOut(duration: 0.85).repeatCount(2, autoreverses: true)) {
                sweep = true
            }
            withAnimation(.easeInOut(duration: 1.10)) {
                progress = 1
            }

            try? await Task.sleep(nanoseconds: 260_000_000)
            withAnimation(.easeOut(duration: 0.40)) {
                hintIn = true
            }

            try? await Task.sleep(nanoseconds: 1_060_000_000)
            finish()
        }
    }

    /// Ends the animation and reports upwards. Guarded so a tap, the timer and
    /// the natural end can all fire without a double hand-off.
    private func finish() {
        guard visible else { return }
        withAnimation(.easeInOut(duration: 0.32)) {
            visible = false
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            onFinish()
        }
    }
}

// MARK: - Tints
//
// Two stops of the system accent, kept local so the splash does not depend on a
// palette entry that other screens may re-tune.

private enum LaunchTint {
    static let glow = Palette.accent
    static let deep = Color(red: 0.055, green: 0.243, blue: 0.627)
}

// MARK: - Presenter

/// Owns the splash window and the play-once gate.
///
/// Cold launch is the whole point: the gate is a process-wide flag, so returning
/// to the foreground never replays it.
@MainActor
enum LaunchSplash {

    /// Flipped once the splash has actually been put on screen. A second caller -
    /// another view, or `RootView` once the parent merges that line - finds it set
    /// and does nothing. Only set on success, so a call that found no window scene
    /// leaves the gate open instead of burning the one play of this launch.
    private static var played = false

    private static var window: UIWindow?
    private static var watchdog: Task<Void, Never>?

    /// Presents the splash if this process has not played it yet.
    ///
    /// Safe from any view's `onAppear`: with no window scene yet it returns
    /// without doing anything, and the rest of the app is unaffected.
    static func presentIfNeeded() {
        guard !played else { return }
        guard window == nil, let scene = activeScene() else { return }
        played = true

        let root = LaunchAnimationView(onFinish: { LaunchSplash.dismiss() })
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear

        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 100
        w.backgroundColor = .clear
        w.isOpaque = false
        w.rootViewController = host
        // Deliberately not made key: stealing key status from the app window
        // would have to be handed back afterwards, and getting that wrong is how
        // keyboards stop working. A window on top receives touches regardless.
        w.isHidden = false
        window = w

        // Hard stop. Whatever the view does, the splash comes down.
        watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            LaunchSplash.dismiss()
        }
    }

    /// Takes the splash down. Idempotent, and safe to call twice in one turn.
    static func dismiss() {
        watchdog?.cancel()
        watchdog = nil

        guard let w = window else { return }
        window = nil

        // Deferred for the same reason OverlayManager defers: destroying a window
        // while it is mid-dispatch crashes in UIKit.
        DispatchQueue.main.async {
            w.isHidden = true
            w.rootViewController = nil
        }
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}
