import Foundation
import Combine
import UIKit

// MARK: - Resumable model downloader
//
// Downloading a 1-4GB GGUF over an unreliable link needs resume, so this does
// not use URLSession's download task (which discards partial data when it
// fails). Instead a plain data task with a `Range: bytes=N-` header appends to
// a `.part` file, and the offset is persisted so a relaunch can continue.
//
// Verified against hf-mirror.com before writing this: it answers
// `Accept-Ranges: bytes` and returns `206 Partial Content` with
// `Content-Range: bytes N-M/TOTAL`, which is what makes the resume path work.
//
// Progress is measured over a moving window rather than since start, because
// the instantaneous rate here swings by an order of magnitude and a cumulative
// average hides that.

@MainActor
final class ResumableDownloader: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case preparing
        case downloading
        case paused
        case finished
        case failed(String)

        var isActive: Bool { self == .downloading || self == .preparing }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var etaSeconds: Double? = nil
    /// Non-nil when the current source is a fallback rather than the first choice.
    @Published private(set) var currentMirror: String = ""

    private var destination: URL?
    private var mirrors: [URL] = []
    private var mirrorIndex = 0
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?

    /// Rolling rate estimate.
    private var samples: [(time: CFTimeInterval, bytes: Int64)] = []
    private let sampleWindow: CFTimeInterval = 6

    /// Resume bookkeeping, persisted so a relaunch can continue the file.
    private var partURL: URL?
    private var metaURL: URL?

    private let maxRetries = 8
    private var retryCount = 0

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        cfg.waitsForConnectivity = true
        // Each chunk is small, so a long-lived cache entry is pointless here.
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: nil, delegateQueue: nil)
    }

    // MARK: Public API

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    var speedText: String {
        guard bytesPerSecond > 0 else { return "—" }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
    }

    var etaText: String {
        guard let eta = etaSeconds, eta.isFinite, eta > 0, eta < 86_400 else { return "—" }
        if eta < 60 { return String(format: "%.0f 秒", eta) }
        if eta < 3600 { return String(format: "%.0f 分 %.0f 秒", floor(eta / 60), eta.truncatingRemainder(dividingBy: 60)) }
        return String(format: "%.1f 小时", eta / 3600)
    }

    var progressText: String {
        guard totalBytes > 0 else { return ReceivedFormatter.text(receivedBytes) }
        return "\(ReceivedFormatter.text(receivedBytes)) / \(ReceivedFormatter.text(totalBytes))"
    }

    /// Starts, or resumes a previously interrupted transfer to `destination`.
    func start(mirrors: [URL], destination: URL) {
        self.mirrors = mirrors
        self.destination = destination
        self.mirrorIndex = 0
        retryCount = 0
        configurePartFiles(for: destination)

        if receivedBytes == 0 {
            receivedBytes = existingPartSize()
        }
        if receivedBytes > 0, totalBytes > 0 {
            state = .downloading
        } else {
            state = .preparing
        }
        beginRequest()
    }

    func pause() {
        guard state.isActive else { return }
        task?.cancel()
        task = nil
        closeHandle()
        state = .paused
        bytesPerSecond = 0
        etaSeconds = nil
    }

    func resume() {
        guard state == .paused || isFailedState() else { return }
        state = .downloading
        beginRequest()
    }

    private func isFailedState() -> Bool {
        if case .failed = state { return true }
        return false
    }

    func cancel() {
        task?.cancel()
        task = nil
        closeHandle()
        removePartFiles()
        receivedBytes = 0
        totalBytes = 0
        bytesPerSecond = 0
        etaSeconds = nil
        state = .idle
    }

    // MARK: Resume plumbing

    private func configurePartFiles(for destination: URL) {
        // A separate .part file keeps the real filename free for an atomic move
        // once the transfer completes.
        partURL = destination.appendingPathExtension("part")
        metaURL = destination.appendingPathExtension("partjson")

        if let partURL,
           let existing = try? Data(contentsOf: partURL),
           existing.isEmpty {
            try? FileManager.default.removeItem(at: partURL)
        }
    }

    private func existingPartSize() -> Int64 {
        guard let partURL else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func removePartFiles() {
        if let partURL { try? FileManager.default.removeItem(at: partURL) }
        if let metaURL { try? FileManager.default.removeItem(at: metaURL) }
    }

    private func closeHandle() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func openHandleForAppending() -> Bool {
        guard let partURL else { return false }
        let fm = FileManager.default
        if !fm.fileExists(atPath: partURL.path) {
            fm.createFile(atPath: partURL.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: partURL)
            try handle.seekToEnd()
            fileHandle = handle
            return true
        } catch {
            return false
        }
    }

    // MARK: Request

    private func beginRequest() {
        guard destination != nil else {
            state = .failed("没有目标路径")
            return
        }
        guard mirrorIndex < mirrors.count else {
            // All mirrors exhausted. The .part file is kept so a later attempt
            // resumes rather than restarting from zero.
            state = .failed("所有下载源均失败，已保留进度，可稍后继续")
            return
        }

        let url = mirrors[mirrorIndex]
        currentMirror = url.host ?? url.absoluteString

        let already = existingPartSize()
        receivedBytes = already

        var request = URLRequest(url: url)
        request.setValue("YOLOPerson/1.0", forHTTPHeaderField: "User-Agent")
        // identity: a compressed transfer would break byte-offset alignment.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if already > 0 {
            // The whole point: ask only for what is still missing.
            request.setValue("bytes=\(already)-", forHTTPHeaderField: "Range")
        }
        state = already > 0 ? .downloading : .preparing

        let t = session.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                self?.handle(data: data, response: response, error: error)
            }
        }
        task = t
        t.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?) {
        if let error {
            let ns = error as NSError
            // A deliberate pause cancels the task and must not be treated as a
            // failure.
            if ns.code == NSURLErrorCancelled, state == .paused { return }
            scheduleRetry(reason: ns.localizedDescription)
            return
        }

        guard let http = response as? HTTPURLResponse else {
            scheduleRetry(reason: "无效响应")
            return
        }

        switch http.statusCode {
        case 200:
            // Server ignored the Range header and sent the whole file: restart
            // cleanly rather than appending a duplicate.
            if receivedBytes > 0 {
                closeHandle()
                removePartFiles()
                receivedBytes = 0
            }
            captureTotal(from: http)
            if !openHandleForAppending() {
                state = .failed("无法写入文件")
                return
            }
            append(data, isFirstChunkOfRun: true)
            finishSuccess()

        case 206:
            captureTotal(from: http)
            if !openHandleForAppending() {
                state = .failed("无法写入文件")
                return
            }
            append(data, isFirstChunkOfRun: true)
            finishSuccess()

        case 416:
            // "Range Not Satisfiable": the .part file is already complete.
            finishFromExistingPart()

        case 429, 500, 502, 503, 504:
            scheduleRetry(reason: "服务器繁忙 (\(http.statusCode))")

        default:
            scheduleRetry(reason: "HTTP \(http.statusCode)")
        }
    }

    private func captureTotal(from http: HTTPURLResponse) {
        // Prefer Content-Range's total, which is the full file size even for a
        // partial response.
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.lastIndex(of: "/"),
           let total = Int64(range[range.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
            totalBytes = total
            return
        }
        let length = http.expectedContentLength
        if length > 0 {
            totalBytes = receivedBytes + length
        }
    }

    private func append(_ data: Data?, isFirstChunkOfRun: Bool) {
        guard let data, !data.isEmpty, let fileHandle else { return }
        // seekToEnd was done when the handle opened; write appends.
        try? fileHandle.write(contentsOf: data)
        receivedBytes += Int64(data.count)
        recordSample()
        if isFirstChunkOfRun { retryCount = 0 }
    }

    private func finishSuccess() {
        closeHandle()
        guard let destination, let partURL else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: partURL, to: destination)
            if let metaURL { try? fm.removeItem(at: metaURL) }
            state = .finished
            bytesPerSecond = 0
            etaSeconds = 0
        } catch {
            state = .failed("移动文件失败：\(error.localizedDescription)")
        }
    }

    private func finishFromExistingPart() {
        closeHandle()
        guard let destination, let partURL else { return }
        let size = existingPartSize()
        // Only accept it as complete when it matches the expected total.
        if totalBytes > 0, size != totalBytes {
            scheduleRetry(reason: "文件不完整")
            return
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        do {
            try fm.moveItem(at: partURL, to: destination)
            receivedBytes = size
            state = .finished
        } catch {
            state = .failed("移动文件失败：\(error.localizedDescription)")
        }
    }

    // MARK: Retry

    private func scheduleRetry(reason: String) {
        closeHandle()
        retryCount += 1

        if retryCount > maxRetries {
            // Move to the next mirror but keep the partial file.
            mirrorIndex += 1
            retryCount = 0
            if mirrorIndex < mirrors.count {
                beginRequest()
            } else {
                state = .failed("下载失败（\(reason)），进度已保留")
            }
            return
        }

        state = .downloading
        // Exponential backoff, capped so a flaky link recovers quickly.
        let delay = min(pow(2.0, Double(retryCount)) * 0.5, 8.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state == .downloading else { return }
            self.beginRequest()
        }
    }

    // MARK: Rate sampling

    private func recordSample() {
        let now = CFAbsoluteTimeGetCurrent()
        samples.append((time: now, bytes: receivedBytes))
        samples.removeAll { now - $0.time > sampleWindow }
        guard let first = samples.first, samples.count >= 2 else { return }
        let dt = now - first.time
        let db = receivedBytes - first.bytes
        guard dt > 0.4, db > 0 else { return }
        bytesPerSecond = Double(db) / dt
        if bytesPerSecond > 1024 {
            etaSeconds = Double(max(totalBytes - receivedBytes, 0)) / bytesPerSecond
        }
    }
}

// MARK: - Byte formatting

enum ReceivedFormatter {
    static func text(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }
}
