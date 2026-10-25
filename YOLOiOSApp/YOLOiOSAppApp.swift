import SwiftUI

// MARK: - WhyJ1ng AI (formerly YOLO Person)
// Access password: 123456
//
// Startup is deliberately instrumented: every stage is written to boot.log
// before it runs, so a launch crash leaves a trail showing exactly how far the
// app got. BootLog uses nothing but FileHandle so it survives almost anything.

@main
struct YOLOiOSAppApp: App {
    @StateObject private var appState: AppState
    @StateObject private var engine: YOLOViewModel

    init() {
        // BootLog first: it must work even if everything below fails.
        BootLog.beginRun()
        BootLog.stage("App.init entered")

        // Decide safe mode before building any subsystem.
        SafeMode.shared.evaluate()
        BootLog.stage("SafeMode.isEngaged=\(SafeMode.shared.isEngaged) failures=\(SafeMode.shared.consecutiveFailures)")

        BootLog.stage("CrashReporter.install")
        CrashReporter.install()

        BootLog.stage("AppState.init")
        _appState = StateObject(wrappedValue: AppState())
        BootLog.stage("YOLOViewModel.init")
        _engine = StateObject(wrappedValue: YOLOViewModel())

        BootLog.stage("App.init finished")
    }

    var body: some Scene {
        WindowGroup {
            InstrumentedRoot(appState: appState, engine: engine)
        }
    }
}

/// Wraps `RootView` so the moment the first view is constructed gets logged.
/// A wrapper is used rather than logging inside the `WindowGroup` closure
/// because that closure is a `ViewBuilder` and cannot hold statements.
struct InstrumentedRoot: View {
    let appState: AppState
    let engine: YOLOViewModel

    init(appState: AppState, engine: YOLOViewModel) {
        self.appState = appState
        self.engine = engine
        BootLog.stage("InstrumentedRoot.init (first view built)")
    }

    var body: some View {
        RootView()
            .environmentObject(appState)
            .environmentObject(engine)
            .preferredColorScheme(.light)
            .tint(Palette.accent)
            .onAppear {
                BootLog.stage("InstrumentedRoot.onAppear (first frame)")
                if !SafeMode.shared.isEngaged {
                    OverlayState.shared.attach(engine: engine, app: appState)
                }
                SafeMode.shared.markCompleted()
                CrashReporter.markLaunchCompleted()
                BootLog.stage("launch marked complete")
            }
            .onReceive(appState.$models) { _ in
                OverlayState.shared.syncModels()
            }
            .onReceive(appState.$selectedModel) { _ in
                OverlayState.shared.syncModels()
            }
    }
}
