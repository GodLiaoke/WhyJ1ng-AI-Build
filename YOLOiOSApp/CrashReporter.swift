import Foundation
import Darwin
import UIKit

// MARK: - Crash reporter
//
// The app cannot be debugged from a desk, so a crash has to leave evidence
// behind. A readable report is written into Documents/CrashLogs and surfaced in
// Settings so it can be copied out without a cable.
//
// Constraints that shape this file:
//   * A C function pointer cannot capture context, so every callback is a
//     file-scope function and all mutable state it touches is a global.
//   * A signal handler may only perform async-signal-safe work, so the file
//     descriptor is opened once at install time and the handler does nothing
//     but `write` a fixed message. The signal number is written as the first
//     byte so the reader can tell which signal fired.

// MARK: File-scope state (required: C callbacks cannot capture)

/// Descriptor for the signal log, opened once at install time.
private var gCrashFD: Int32 = -1

/// Fixed text written on a fatal signal. A literal avoids allocating in the
/// handler, which would not be async-signal-safe.
private let gCrashMessage: [CChar] = Array(
    "A fatal signal terminated the process. The first byte of this file is the signal number.\n".utf8CString
)

/// Signal handler. Must not capture, allocate, or call Foundation.
private func crashSignalHandler(_ sig: Int32) {
    if gCrashFD >= 0 {
        // First byte: the signal number, so the reader knows which one fired.
        var code = UInt8(truncatingIfNeeded: sig)
        withUnsafePointer(to: &code) { ptr in
            _ = Darwin.write(gCrashFD, ptr, 1)
        }
        gCrashMessage.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                _ = Darwin.write(gCrashFD, base, buf.count - 1)
            }
        }

        // Return addresses of the crashing thread. `backtrace` is
        // async-signal-safe; the hex formatting below is hand-rolled because
        // snprintf is not guaranteed to be, and it avoids any allocation.
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = frames.withUnsafeMutableBufferPointer { buf -> Int32 in
            backtrace(buf.baseAddress, Int32(buf.count))
        }
        if count > 0 {
            _ = Darwin.write(gCrashFD, gBacktraceHeader, gBacktraceHeader.count - 1)
            for i in 0..<Int(count) {
                writeFrame(index: i, address: frames[i])
            }
        }
        fsync(gCrashFD)
    }
    // Restore the default action and re-raise so the process still dies the way
    // the system expects.
    signal(sig, SIG_DFL)
    raise(sig)
}

private let gBacktraceHeader = Array("backtrace (raw addresses, not symbolicated):\n".utf8CString)

/// ASCII hex digits. A plain byte table is used instead of `String` indexing
/// because string subscripting can allocate, which is not signal-safe.
private let gHexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

/// Writes one `  N: 0xADDRESS\n` line with no allocation and no libc formatting.
private func writeFrame(index: Int, address: UnsafeMutableRawPointer?) {
    guard gCrashFD >= 0 else { return }
    var out = [UInt8](repeating: 0, count: 32)
    var n = 0

    out[n] = 0x20; n += 1                                   // space
    out[n] = 0x20; n += 1                                   // space
    // Decimal index; at most two digits since we record 64 frames.
    if index >= 10 { out[n] = UInt8(0x30 + index / 10); n += 1 }
    out[n] = UInt8(0x30 + index % 10); n += 1
    out[n] = 0x3A; n += 1                                   // ':'
    out[n] = 0x20; n += 1                                   // space
    out[n] = 0x30; n += 1                                   // '0'
    out[n] = 0x78; n += 1                                   // 'x'

    let value = UInt(bitPattern: address)
    for shift in stride(from: 60, through: 0, by: -4) {
        let nibble = Int((value >> UInt(shift)) & 0xF)
        out[n] = gHexDigits[nibble]
        n += 1
    }
    out[n] = 0x0A; n += 1                                   // newline

    out.withUnsafeBufferPointer { buf in
        if let base = buf.baseAddress {
            _ = Darwin.write(gCrashFD, base, n)
        }
    }
}

/// Uncaught Objective-C exception handler. Not restricted to signal-safe work.
private func crashExceptionHandler(_ exception: NSException) {
    CrashReporter.record(exception: exception)
}

// MARK: Reporter

enum CrashReporter {

    private static var installed = false
    private static let maxReports = 10

    /// Set while a launch is in progress. A leftover marker on the next run
    /// means the previous run died before it finished starting, which is the
    /// one failure mode no in-process handler can record.
    private static let launchMarkerKey = "crash.launchInProgress"

    static var logsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CrashLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Lifecycle

    static func install() {
        guard !installed else { return }
        installed = true

        // Open the signal log once. The handler then only needs to write.
        let signalLog = logsDirectory.appendingPathComponent("signal.log")
        gCrashFD = open(signalLog.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)

        NSSetUncaughtExceptionHandler(crashExceptionHandler)

        // SIGKILL and SIGSTOP cannot be caught.
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig, crashSignalHandler)
        }

        detectIncompleteLaunch()
    }

    /// Call first thing at launch, before anything else can fail.
    static func beginLaunch() {
        UserDefaults.standard.set(true, forKey: launchMarkerKey)
    }

    /// Call once the first frame has rendered.
    static func markLaunchCompleted() {
        UserDefaults.standard.set(false, forKey: launchMarkerKey)
    }

    private static func detectIncompleteLaunch() {
        let d = UserDefaults.standard
        guard d.bool(forKey: launchMarkerKey) else { return }
        d.set(false, forKey: launchMarkerKey)
        append("""
        [Previous launch did not complete]
        The app started but never reached its first rendered frame, so the
        previous run died during startup. Likely a crash inside a singleton
        initialiser, a view body evaluated early, or the SwiftUI environment
        setup. See signal.log for the signal number if one was recorded.
        """, to: fileNamed("incomplete-launch.log"))
    }

    // MARK: Recording

    fileprivate static func record(exception: NSException) {
        let stack = exception.callStackSymbols.joined(separator: "\n")
        append("""
        [Uncaught Objective-C exception]
        name   : \(exception.name.rawValue)
        reason : \(exception.reason ?? "nil")
        stack  :
        \(stack)
        """, to: fileNamed("exception.log"))
    }

    private static func append(_ text: String, to url: URL) {
        let header = """
        ===== \(AppBrand.name) crash report =====
        app     : \(AppBrand.name) \(AppBrand.channel)
        version : \(AppBrand.buildVersion)
        system  : \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        model   : deviceIdentifier

        """
        // Reports are small; rewriting is simpler than appending and keeps the
        // file valid if two crashes land in the same second.
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let payload = existing.isEmpty
            ? header + text + "\n"
            : existing + "\n----\n" + text + "\n"
        try? payload.write(to: url, atomically: true, encoding: .utf8)
        prune()
    }

    private static func fileNamed(_ name: String) -> URL {
        logsDirectory.appendingPathComponent(name)
    }

    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logsDirectory,
                                                      includingPropertiesForKeys: [.creationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(maxReports) { try? fm.removeItem(at: old) }
    }

    // MARK: Reading

    struct Report: Identifiable {
        let id: String
        let url: URL
        let modified: Date

        /// Rendered text, with the leading signal byte translated.
        var text: String {
            guard var raw = try? Data(contentsOf: url) else { return "" }
            guard let head = raw.first, head < 32, raw.count > 1 else {
                return String(data: raw, encoding: .utf8) ?? "(unreadable)"
            }
            raw.removeFirst()
            let body = String(data: raw, encoding: .utf8) ?? ""
            return "[Fatal signal \(head): \(Self.signalName(Int32(head)))]\n" + body
        }

        var name: String { url.deletingPathExtension().lastPathComponent }

        static func signalName(_ sig: Int32) -> String {
            switch sig {
            case SIGABRT: return "SIGABRT — abort: assert / fatalError / uncaught exception"
            case SIGILL:  return "SIGILL — illegal instruction"
            case SIGSEGV: return "SIGSEGV — invalid memory access"
            case SIGFPE:  return "SIGFPE — arithmetic error"
            case SIGBUS:  return "SIGBUS — invalid memory access (misaligned or mapped file)"
            case SIGTRAP: return "SIGTRAP — trap: Swift runtime check or force-unwrap of nil"
            default:      return "unknown"
            }
        }
    }

    static func reports() -> [Report] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { url -> Report? in
            guard url.pathExtension == "log" else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            return Report(id: url.path, url: url, modified: date)
        }
        .sorted { $0.modified > $1.modified }
    }

    static func clearAll() {
        // Reopen the signal log so it survives the sweep.
        if gCrashFD >= 0 { close(gCrashFD); gCrashFD = -1 }
        for r in reports() { try? FileManager.default.removeItem(at: r.url) }
        let signalLog = logsDirectory.appendingPathComponent("signal.log")
        gCrashFD = open(signalLog.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    }
}
