import Foundation

// MARK: - Boot log
//
// The lowest-risk diagnostic in the app. It appends one line per startup stage
// using nothing but FileHandle, so it survives crashes that happen before any
// other subsystem is alive (including before the crash reporter itself).
//
// If the app dies during launch, this file shows exactly how far it got, which
// is the one thing no signal handler can tell you.
//
// Deliberately dependency-free: no AppBrand, no UIKit, no UserDefaults.

enum BootLog {

    private static let fileName = "boot.log"

    /// Documents/CrashLogs/boot.log — resolved without touching UIKit.
    static var url: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = docs.appendingPathComponent("CrashLogs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(fileName)
    }

    /// Appends a timestamped stage marker. Never throws, never fatal.
    static func stage(_ name: String) {
        let line = "\(stamp())  \(name)\n"
        guard let data = line.data(using: .utf8) else { return }

        let path = url.path
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        // Bound the file so a crash loop cannot fill the disk.
        if let size = try? handle.seekToEnd(), size > 256 * 1024 {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Marks the start of a run so old entries are visually separated.
    static func beginRun() {
        stage("──────── launch ────────")
    }

    static func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "(no boot log)"
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}

// MARK: - Safe mode
//
// If the previous run died before finishing startup, this run disables every
// optional subsystem — overlay window, LLM, camera — so the app can reach a
// screen where the logs are readable. A crash loop is otherwise unrecoverable
// without deleting the app.
//
// The counter is stored in UserDefaults and is the only state involved. It is
// incremented at launch and cleared once the first frame is up, so a leftover
// value means the previous run never got that far.

@MainActor
final class SafeMode: ObservableObject {
    static let shared = SafeMode()

    private static let key = "boot.incompleteLaunchCount"

    /// True when the previous launch did not complete.
    @Published private(set) var isEngaged = false
    /// Number of consecutive launches that failed to finish starting.
    @Published private(set) var consecutiveFailures = 0

    private init() {}

    /// Reads the marker left by the previous run and decides whether to engage.
    /// Call as early as possible, before any subsystem is built.
    func evaluate() {
        let d = UserDefaults.standard
        consecutiveFailures = d.integer(forKey: Self.key)
        isEngaged = consecutiveFailures > 0

        // Reserve this launch. Cleared by markCompleted() on success, so a
        // value left behind always means the run died before its first frame.
        d.set(consecutiveFailures + 1, forKey: Self.key)

        if isEngaged {
            BootLog.stage("SAFE MODE engaged (previous launch failed; streak=\(consecutiveFailures))")
        }
    }

    /// The app reached its first frame. Always clears the counter: the earlier
    /// version compared against the in-memory value, which was the pre-launch
    /// count, so it bailed out and left the marker set after every healthy run.
    func markCompleted() {
        UserDefaults.standard.set(0, forKey: Self.key)
        consecutiveFailures = 0
        isEngaged = false
    }

    /// Leaves safe mode without relaunching.
    func clearAndContinue() {
        UserDefaults.standard.set(0, forKey: Self.key)
        consecutiveFailures = 0
        isEngaged = false
        BootLog.stage("safe mode cleared by user, continuing")
    }

    /// Manual opt-in from the diagnostics screen.
    func forceNextLaunch() {
        UserDefaults.standard.set(1, forKey: Self.key)
    }
}
