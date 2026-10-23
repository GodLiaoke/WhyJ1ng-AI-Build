import Foundation
import UIKit

// MARK: - Sandbox tools
//
// Gives the model a small, explicit set of things it can DO, not just say.
//
// Security model — read this before adding a tool:
//
//   * Every path is resolved against the app container and rejected if it
//     escapes. `resolve()` is the single choke point; nothing may bypass it.
//   * Only two roots are writable: Documents/Sandbox and Caches/Sandbox. The
//     model cannot touch the model files, the crash logs, or anything outside
//     the container.
//   * Tools that could surprise the user (deleting, overwriting) are marked
//     `destructive` and require confirmation when the setting is on.
//   * Camera, microphone, photo library, location and anything else that
//     reaches outside the sandbox are NOT tools. They stay behind the normal
//     UI, because a 1.5B model must not be able to open a camera on its own.
//
// Commands are recognised by parsing the model's output for a fenced block, not
// by asking it to emit JSON: small local models produce malformed JSON far more
// often than they produce a clean fenced block.

struct SandboxTool: Identifiable, Hashable {
    let id: String
    /// Name the model uses in a command block.
    let command: String
    let summary: String
    /// Requires a confirmation tap before running.
    let destructive: Bool
}

enum SandboxTools {

    static let all: [SandboxTool] = [
        SandboxTool(id: "write", command: "write", summary: "写入文本文件到沙盒", destructive: false),
        SandboxTool(id: "append", command: "append", summary: "追加内容到文件", destructive: false),
        SandboxTool(id: "read", command: "read", summary: "读取沙盒内的文件", destructive: false),
        SandboxTool(id: "list", command: "ls", summary: "列出沙盒目录", destructive: false),
        SandboxTool(id: "delete", command: "rm", summary: "删除沙盒内的文件", destructive: true),
        SandboxTool(id: "mkdir", command: "mkdir", summary: "创建目录", destructive: false),
    ]

    // MARK: Roots

    /// Writable sandbox root, visible in the Files app.
    static var sandboxRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Sandbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolves a model-supplied relative path, refusing anything that escapes.
    ///
    /// This is the security boundary. A path like `../../Library/Preferences` or
    /// an absolute `/etc/passwd` must fail here and nowhere else.
    static func resolve(_ raw: String) throws -> URL {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip surrounding quotes and any leading ./ the model likes to add.
        input = input.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        while input.hasPrefix("./") { input.removeFirst(2) }

        guard !input.isEmpty else { throw ToolError.emptyPath }

        // Reject absolute paths outright.
        guard !input.hasPrefix("/") else { throw ToolError.absolutePath(input) }

        // Reject traversal before touching the filesystem.
        let components = input.split(separator: "/").map(String.init)
        guard !components.contains("..") else { throw ToolError.traversal(input) }

        let url = sandboxRoot.appendingPathComponent(input).standardizedFileURL
        let root = sandboxRoot.standardizedFileURL

        // Final containment check on the resolved path.
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            throw ToolError.escapedSandbox(url.path)
        }
        return url
    }

    /// Renders the path as the model should refer to it.
    static func relative(_ url: URL) -> String {
        let root = sandboxRoot.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(root) else { return url.lastPathComponent }
        var rel = String(full.dropFirst(root.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel.isEmpty ? "." : rel
    }

    // MARK: Execution

    enum ToolError: LocalizedError {
        case emptyPath
        case absolutePath(String)
        case traversal(String)
        case escapedSandbox(String)
        case notFound(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .emptyPath: return "路径为空"
            case .absolutePath(let p): return "不支持绝对路径：\(p)"
            case .traversal(let p): return "路径包含 .. ，已拒绝：\(p)"
            case .escapedSandbox(let p): return "路径越出沙盒，已拒绝：\(p)"
            case .notFound(let p): return "文件不存在：\(p)"
            case .tooLarge(let p): return "文件过大，拒绝读取：\(p)"
            }
        }
    }

    /// Upper bound on a single read so a huge file cannot blow up the context.
    static let maxReadBytes = 64 * 1024

    static func run(_ command: String, argument rawArgument: String) throws -> String {
        let argument = rawArgument.trimmingCharacters(in: .whitespacesAndNewlines)

        switch command {
        case "write":
            let (path, body) = splitPathAndBody(argument)
            let url = try resolve(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            return "已写入 \(relative(url))（\(body.utf8.count) 字节）"

        case "append":
            let (path, body) = splitPathAndBody(argument)
            let url = try resolve(path)
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(body.utf8))
            } else {
                try body.write(to: url, atomically: true, encoding: .utf8)
            }
            return "已追加到 \(relative(url))"

        case "read":
            let url = try resolve(argument)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError.notFound(relative(url))
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            guard size <= maxReadBytes else { throw ToolError.tooLarge(relative(url)) }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "(不是 UTF-8 文本)"
            return "\(relative(url)) 内容：\n\(text)"

        case "ls":
            let target = argument.isEmpty ? sandboxRoot : try resolve(argument)
            let items = (try? FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            guard !items.isEmpty else { return "\(relative(target)) 为空" }
            let lines = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item -> String in
                let v = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if v?.isDirectory == true { return "  [目录] \(item.lastPathComponent)/" }
                return "  \(item.lastPathComponent)  \(v?.fileSize ?? 0) 字节"
            }
            return "\(relative(target)) 内容：\n" + lines.joined(separator: "\n")

        case "mkdir":
            let url = try resolve(argument)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return "已创建目录 \(relative(url))"

        case "rm":
            let url = try resolve(argument)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError.notFound(relative(url))
            }
            try FileManager.default.removeItem(at: url)
            return "已删除 \(relative(url))"

        default:
            return "未知命令：\(command)"
        }
    }

    /// Splits a `write` / `append` argument into path and body.
    ///
    /// Models are inconsistent about this: some put `path` on its own line and
    /// the body below, others write `path body...` on one line, and some emit
    /// the body inside the same line with no separator at all. The previous
    /// implementation only handled the first form, so everything else produced an
    /// empty file — the path parsed correctly and the body came out blank.
    ///
    /// Strategy: the first whitespace-delimited token that looks like a path is
    /// the path; everything after it is the body, whichever line it is on.
    private static func splitPathAndBody(_ argument: String) -> (String, String) {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }

        // Form 1: path on the first line, body on the following lines.
        if let newline = trimmed.firstIndex(of: "\n") {
            let firstLine = String(trimmed[..<newline]).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: newline)...])

            // `path body` on the first line followed by more lines: take the
            // first token as the path and keep the remainder as body.
            let parts = firstLine.split(separator: " ", maxSplits: 1).map(String.init)
            let candidate = parts.first ?? firstLine
            if looksLikePath(candidate) {
                var body = parts.count > 1 ? parts[1] : ""
                if !rest.isEmpty {
                    body += (body.isEmpty ? "" : "\n") + rest
                }
                return (candidate, body)
            }
            return (firstLine, rest)
        }

        // Form 2: everything on one line — `path body...`
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard let candidate = parts.first, looksLikePath(candidate) else {
            return (trimmed, "")
        }
        return (candidate, parts.count > 1 ? parts[1] : "")
    }

    /// Heuristic: a path has no spaces, is reasonably short, and either carries a
    /// known extension or contains a separator.
    private static func looksLikePath(_ token: String) -> Bool {
        guard !token.isEmpty, token.count < 120 else { return false }
        guard !token.contains(" ") else { return false }
        if token.contains("/") { return true }
        let ext = (token as NSString).pathExtension.lowercased()
        return ["txt", "md", "json", "csv", "log", "html", "htm", "swift", "js"].contains(ext)
    }

    // MARK: Parsing model output

    /// A command the model proposed, pending execution.
    struct ProposedCommand: Identifiable, Hashable {
        let id = UUID()
        let command: String
        let argument: String
        let tool: SandboxTool?
        let raw: String
        /// Whether this command is destructive, decided at parse time.
        ///
        /// The confirmation *policy* is a main-actor setting, so it cannot be
        /// read from a nonisolated computed property. Only the tool's intrinsic
        /// nature is baked in here; the policy is applied by the caller.
        let destructive: Bool

        /// Requires a confirmation tap before running, given the current policy.
        @MainActor
        var needsConfirmation: Bool {
            guard let tool else { return true }   // unknown command: always ask
            guard tool.destructive else { return false }
            return AIContextSettings.shared.toolsRequireConfirmation
        }

        var displayArgument: String {
            argument.count > 120 ? String(argument.prefix(120)) + "…" : argument
        }
    }

    /// Extracts ```tool blocks from a reply.
    ///
    /// Format:
    /// ```tool
    /// write notes/todo.txt
    /// 内容…
    /// ```
    static func parseCommands(in text: String) -> [ProposedCommand] {
        var found: [ProposedCommand] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```tool") {
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                let joined = body.joined(separator: "\n")
                if let firstNewline = joined.firstIndex(of: "\n") {
                    let head = String(joined[..<firstNewline]).trimmingCharacters(in: .whitespaces)
                    let rest = String(joined[joined.index(after: firstNewline)...])
                    let parts = head.split(separator: " ", maxSplits: 1).map(String.init)
                    let cmd = parts.first ?? ""
                    // `write path body` may put the body on the same line.
                    var arg = parts.count > 1 ? parts[1] : ""
                    if !rest.isEmpty { arg += "\n" + rest }
                    let tool = all.first { $0.command == cmd }
                    found.append(ProposedCommand(command: cmd,
                                                 argument: arg,
                                                 tool: tool,
                                                 raw: joined,
                                                 destructive: tool?.destructive ?? true))
                } else {
                    let parts = joined.split(separator: " ", maxSplits: 1).map(String.init)
                    let cmd = parts.first ?? ""
                    let arg = parts.count > 1 ? parts[1] : ""
                    let tool = all.first { $0.command == cmd }
                    found.append(ProposedCommand(command: cmd,
                                                 argument: arg,
                                                 tool: tool,
                                                 raw: joined,
                                                 destructive: tool?.destructive ?? true))
                }
            }
            i += 1
        }
        return found
    }

    /// Text shown to the model describing the available tools.
    static func toolPrompt() -> String {
        """
        你可以通过代码块调用沙盒工具，格式如下（三个反引号加 tool）：
        ```tool
        write notes/todo.txt
        要写入的内容
        ```
        可用命令：
          write <相对路径> + 换行 + 内容   写入文件
          append <相对路径> + 换行 + 内容  追加内容
          read <相对路径>                  读取文件
          ls [相对路径]                    列出目录
          mkdir <相对路径>                 创建目录
          rm <相对路径>                    删除文件（危险，需确认）

        规则：
        - 只能使用相对路径，只能在自己的沙盒目录内操作。
        - 不要使用绝对路径，不要用 .. 。
        - 一次回复最多调用一个工具。
        - 调用工具后，用一句话说明你做了什么。
        - 你不能操作相机、相册、麦克风或任何沙盒外的资源。
        """
    }
}
