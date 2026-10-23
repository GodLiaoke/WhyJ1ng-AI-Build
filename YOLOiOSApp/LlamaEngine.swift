import Foundation
import llama

// MARK: - Availability
//
// The framework is weak-linked (see project.yml) because the official prebuilt
// xcframework is stamped iOS 16.4 minimum. On iOS 15 dyld therefore refuses to
// load it — with a hard link that kills the app before main(), taking the whole
// detector down over a feature most users never open.
//
// Weak-linked, the load failure is survivable but the C symbols resolve to NULL,
// and calling one is a null dereference. So everything below must be gated on
// `LlamaRuntime.isLoaded`, which asks dyld whether the binary is actually
// resident rather than trusting the compile-time import.
enum LlamaRuntime {
    /// A symbol every build of the framework exports. Its presence in the
    /// process means the image loaded; its absence means dyld rejected it.
    private static let sentinel = "llama_backend_init"

    /// False on iOS 15 and on any OS the framework refuses to load into.
    ///
    /// `RTLD_DEFAULT` is `(void *)-2` on Darwin and is not exposed to Swift.
    /// Resolved once: the answer cannot change during a process lifetime.
    static let isLoaded: Bool = {
        // Unwrap twice on purpose: `dlsym` is IUO, so a missing symbol arrives
        // as an implicitly unwrapped nil and would trap if compared directly.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), sentinel) else {
            return false
        }
        return sym != UnsafeMutableRawPointer(bitPattern: 0)
    }()

    /// Why the engine is unavailable, for the UI to show instead of a blank tab.
    static var unavailableReason: String? {
        isLoaded ? nil : "当前系统版本低于该组件所需的 iOS 16.4，对话功能已停用。识别与瞄准不受影响。"
    }
}

// MARK: - llama.cpp engine
//
// Wraps the official llama.cpp C API (pinned to the b11612 XCFramework). All
// work happens off the main thread; the actor serialises access so a generation
// and a model swap can never interleave.
//
// Memory notes:
//   * The model is memory-mapped (LLAMA_LOAD_MODE_MMAP) so weights are paged in
//     from disk by the OS instead of being copied into the process heap. This is
//     the difference between working on an 8GB phone and being jetsam-killed.
//   * `unload()` frees the context and model and returns their pages.

enum LlamaEngineError: LocalizedError {
    case modelNotFound(String)
    case loadFailed(String)
    case contextFailed
    case notLoaded
    case cancelled
    /// The framework itself could not be loaded (iOS below its floor).
    case frameworkUnavailable

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let p): return "找不到模型文件：\(p)"
        case .loadFailed(let s): return "模型加载失败：\(s)"
        case .contextFailed: return "无法创建推理上下文（可能内存不足）"
        case .notLoaded: return "模型未加载"
        case .frameworkUnavailable:
            return LlamaRuntime.unavailableReason ?? "对话组件在当前系统上不可用"
        case .cancelled: return "已取消"
        }
    }
}

/// A streamed chunk of generated text.
///
/// `text` is a DELTA to append, except when `isFinal` is true — then it is the
/// complete, cleaned answer and the caller must REPLACE what it has. The final
/// chunk can be shorter than what was already streamed because a stop sequence
/// cut removes a partial marker from the tail.
struct LlamaChunk: Sendable {
    let text: String
    let tokens: Int
    var isFinal: Bool = false
}

actor LlamaEngine {
    static let shared = LlamaEngine()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var batch: llama_batch?
    private var sampler: UnsafeMutablePointer<llama_sampler>?

    /// Reused so the token loop allocates nothing per token.
    private var transientCChars: [CChar] = []

    private(set) var loadedPath: String?
    private(set) var loadedContextSize: UInt32 = 0
    private(set) var modelDescription: String = ""

    private var isCancelled = false

    /// Capacity of the persistent decode batch.
    private let batchCapacity: Int32 = 512

    private init() {}

    // MARK: Lifecycle

    var isLoaded: Bool { model != nil && context != nil }

    /// Loads a GGUF file with mmap and full Metal offload.
    func load(path: String, contextSize: UInt32) throws {
        // Everything below dereferences weak-linked C symbols. When dyld
        // rejected the framework they are all NULL, so bail before the first
        // call rather than trapping inside llama_model_default_params().
        guard LlamaRuntime.isLoaded else {
            throw LlamaEngineError.frameworkUnavailable
        }
        if loadedPath == path, isLoaded { return }
        unload()

        guard FileManager.default.fileExists(atPath: path) else {
            throw LlamaEngineError.modelNotFound(path)
        }

        llama_backend_init()

        var mparams = llama_model_default_params()
        #if targetEnvironment(simulator)
        mparams.n_gpu_layers = 0        // no usable Metal device in the simulator
        #else
        mparams.n_gpu_layers = 999      // offload everything to Metal
        #endif
        mparams.load_mode = LLAMA_LOAD_MODE_MMAP

        guard let m = llama_model_load_from_file(path, mparams) else {
            llama_backend_free()
            throw LlamaEngineError.loadFailed(path)
        }

        let cpuCount = Int32(ProcessInfo.processInfo.processorCount)
        // Leave headroom: the UI, and in this app the YOLO preview, share the CPU.
        let threads = max(2, min(6, cpuCount - 2))

        var cparams = llama_context_default_params()
        cparams.n_ctx = contextSize
        cparams.n_batch = UInt32(batchCapacity)
        cparams.n_ubatch = UInt32(batchCapacity)
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO

        guard let ctx = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            llama_backend_free()
            throw LlamaEngineError.contextFailed
        }

        model = m
        context = ctx
        vocab = llama_model_get_vocab(m)
        batch = llama_batch_init(batchCapacity, 0, 1)
        loadedPath = path
        loadedContextSize = contextSize
        modelDescription = Self.describe(m)
    }

    func unload() {
        isCancelled = true
        if let b = batch { llama_batch_free(b) }
        batch = nil
        if let s = sampler { llama_sampler_free(s) }
        sampler = nil
        if let c = context { llama_free(c) }
        context = nil
        if let m = model { llama_model_free(m) }
        model = nil
        vocab = nil
        loadedPath = nil
        modelDescription = ""
        loadedContextSize = 0
        transientCChars.removeAll()
        llama_backend_free()
    }

    func cancel() {
        isCancelled = true
    }

    // MARK: Sampling

    private func buildSampler(temperature: Float,
                              topP: Float,
                              repeatPenalty: Float,
                              seed: UInt32) {
        if let s = sampler { llama_sampler_free(s) }
        let params = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(params)

        if repeatPenalty != 1.0 {
            let nVocab = vocab.map { llama_vocab_n_tokens($0) } ?? 0
            // (n_vocab, last_n, repeat, freq, present)
            llama_sampler_chain_add(chain,
                                    llama_sampler_init_penalties(nVocab, 64, repeatPenalty, 0, 0))
        }
        if temperature > 0 {
            if topP > 0, topP < 1 {
                llama_sampler_chain_add(chain, llama_sampler_init_top_p(topP, 1))
            }
            llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        }
        sampler = chain
    }

    // MARK: Generation

    /// Streams a completion. The caller passes already-templated prompt text so
    /// this stays chat-template agnostic.
    nonisolated func generate(prompt: String,
                              temperature: Float,
                              topP: Float,
                              repeatPenalty: Float,
                              maxTokens: Int) -> AsyncThrowingStream<LlamaChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runGeneration(prompt: prompt,
                                                 temperature: temperature,
                                                 topP: topP,
                                                 repeatPenalty: repeatPenalty,
                                                 maxTokens: maxTokens) { chunk in
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.cancel() }
            }
        }
    }

    private func runGeneration(prompt: String,
                               temperature: Float,
                               topP: Float,
                               repeatPenalty: Float,
                               maxTokens: Int,
                               emit: (LlamaChunk) -> Void) throws {
        guard let context, let vocab else { throw LlamaEngineError.notLoaded }
        isCancelled = false

        buildSampler(temperature: temperature,
                     topP: topP,
                     repeatPenalty: repeatPenalty,
                     seed: 1234)

        // Replay the whole conversation each turn: simpler and avoids stale KV
        // state. Prompts here are a few hundred tokens, so it is cheap.
        llama_memory_clear(llama_get_memory(context), true)

        var tokens = tokenize(text: prompt, addBos: true)
        guard !tokens.isEmpty else { return }

        let nCtx = Int(llama_n_ctx(context))
        if tokens.count >= nCtx - 8 {
            // Keep the tail; the system prompt holds the detection context.
            tokens = Array(tokens.suffix(max(16, nCtx - 64)))
        }

        try decodeChunked(tokens, context: context)

        var produced = 0
        var position = Int32(tokens.count)
        /// Everything generated this turn, before cleanup.
        var full = ""
        /// How many characters of `full` have already been handed to the caller.
        /// The engine emits deltas against this, never the whole buffer.
        var emittedChars = 0

        while produced < maxTokens {
            if Task.isCancelled || isCancelled { throw LlamaEngineError.cancelled }
            if Int(position) >= nCtx - 1 { break }
            guard let sampler else { break }

            // idx -1 samples from the logits of the last decoded token.
            let token = llama_sampler_sample(sampler, context, -1)
            llama_sampler_accept(sampler, token)

            if llama_vocab_is_eog(vocab, token) { break }

            let piece = tokenToPiece(token)
            let text = consumeUTF8(piece)
            produced += 1
            if !text.isEmpty { full += text }

            // Stop sequences such as `<|im_end|>` are commonly split across
            // several tokens, so matching them piece by piece never fires. A
            // rolling window over the accumulated text catches them wherever
            // they land.
            if let stop = Self.stopMarker(in: full) {
                // The answer is everything before the marker, cleaned. This is
                // authoritative even though it may be shorter than what was
                // already streamed, because the cut removes the partial marker
                // from the tail.
                let head = String(full[..<stop.lowerBound])
                emit(LlamaChunk(text: Self.stripControlTokens(head),
                                tokens: produced,
                                isFinal: true))
                break
            }

            // Stream only the part that is safely beyond any partial marker, so
            // a half-written marker never reaches the screen. The buffer holds
            // raw text, so it is cleaned here rather than at accumulation time.
            let visible = Self.stripControlTokens(Self.safeVisiblePortion(full))
            if visible.count > emittedChars {
                emit(LlamaChunk(text: String(visible.dropFirst(emittedChars)),
                                tokens: produced))
                emittedChars = visible.count
            }

            try decodeOne(token, at: position, context: context)
            position += 1
        }

        // EOG / context limit / max tokens: hand over the authoritative text.
        emit(LlamaChunk(text: Self.stripControlTokens(full),
                        tokens: produced,
                        isFinal: true))
    }

    /// Returns `text` minus a tail that could still turn into a stop marker.
    ///
    /// The hold length is the longest marker, not the longest marker minus one:
    /// a fragment such as `im_end|` is what reaches the screen when the hold is
    /// too short, because those characters are the middle of a marker whose
    /// leading `<|` was already emitted. Holding one extra character costs a
    /// single token of latency.
    static func safeVisiblePortion(_ text: String) -> String {
        let hold = (stopMarkers.map(\.count).max() ?? 0) + 1
        guard text.count > hold else { return "" }
        let cut = text.index(text.endIndex, offsetBy: -hold)
        return String(text[..<cut])
    }

    // MARK: Stop sequences

    /// Markers that terminate a turn. Written with unicode escapes so the source
    /// file stays pure ASCII.
    ///
    /// The bare `|im_end|` forms matter: quantised models routinely drop the
    /// angle brackets while emitting the marker anyway, and a stop list that
    /// only matches the well-formed spelling misses those turns entirely.
    static let stopMarkers: [String] = [
        "<\u{007C}im_end\u{007C}>",
        "<\u{007C}im_start\u{007C}>",
        "\u{007C}im_end\u{007C}",
        "\u{007C}im_start\u{007C}",
        "<\u{FF5C}im_end\u{FF5C}>",
        "<\u{FF5C}im_start\u{FF5C}>",
        "\u{FF5C}im_end\u{FF5C}",
        "\u{FF5C}im_start\u{FF5C}",
        "<\u{007C}eot_id\u{007C}>",
        "<\u{007C}endoftext\u{007C}>",
        "<\u{007C}end\u{007C}>",
        "<\u{FF5C}output\u{FF5C}>",
        "<\u{007C}output\u{007C}>",
        "</output>",
        "<output>",
        // Generated-content banners some finetunes wrap their body in.
        "[\u{751F}\u{6210}\u{5185}\u{5BB9}\u{5F00}\u{59CB}]",
        "[\u{751F}\u{6210}\u{5185}\u{5BB9}\u{7ED3}\u{675F}]",
    ]

    /// Finds the earliest stop marker in `text`, if any.
    static func stopMarker(in text: String) -> Range<String.Index>? {
        var best: Range<String.Index>? = nil
        for marker in stopMarkers {
            if let r = text.range(of: marker) {
                if best == nil || r.lowerBound < best!.lowerBound { best = r }
            }
        }
        return best
    }

    /// Returns the portion of `text` after everything already emitted.
    ///
    /// Decodes a long token list in `n_batch`-sized chunks.
    private func decodeChunked(_ tokens: [llama_token], context: OpaquePointer) throws {
        guard batch != nil else { throw LlamaEngineError.notLoaded }
        var offset = 0
        let cap = Int(batchCapacity)
        while offset < tokens.count {
            let slice = Array(tokens[offset..<min(offset + cap, tokens.count)])
            try withBatch(count: slice.count) { b in
                for (i, tok) in slice.enumerated() {
                    let isLast = (offset + i) == tokens.count - 1
                    writeEntry(&b, index: i, token: tok,
                               pos: Int32(offset + i), logits: isLast)
                }
            }
            if llama_decode(context, batch!) != 0 {
                throw LlamaEngineError.loadFailed("llama_decode failed (prompt)")
            }
            offset += slice.count
        }
    }

    private func decodeOne(_ token: llama_token,
                           at position: Int32,
                           context: OpaquePointer) throws {
        guard batch != nil else { throw LlamaEngineError.notLoaded }
        try withBatch(count: 1) { b in
            writeEntry(&b, index: 0, token: token, pos: position, logits: true)
        }
        if llama_decode(context, batch!) != 0 {
            throw LlamaEngineError.loadFailed("llama_decode failed (token)")
        }
    }

    /// Resets the persistent batch to `count` usable slots.
    private func withBatch(count: Int, _ body: (inout llama_batch) -> Void) throws {
        guard var b = batch else { throw LlamaEngineError.notLoaded }
        b.n_tokens = Int32(count)
        body(&b)
        batch = b
    }

    private func writeEntry(_ b: inout llama_batch,
                            index: Int,
                            token: llama_token,
                            pos: llama_pos,
                            logits: Bool) {
        b.token[index] = token
        b.pos[index] = pos
        b.n_seq_id[index] = 1
        b.seq_id[index]?[0] = 0
        b.logits[index] = logits ? 1 : 0
    }

    // MARK: Tokenisation helpers

    func tokenize(text: String, addBos: Bool) -> [llama_token] {
        guard LlamaRuntime.isLoaded else { return [] }
        guard let vocab else { return [] }
        let utf8 = Array(text.utf8)
        let byteCount = utf8.count
        let capacity = byteCount + 8
        guard capacity > 8 else { return [] }

        var tokens = [llama_token](repeating: 0, count: capacity)
        // Snapshot the sizes first: reading `.count` while the same array is
        // borrowed by withUnsafe... is an overlapping exclusive access.
        let tokenCapacity = capacity

        let count = tokens.withUnsafeMutableBufferPointer { buf -> Int32 in
            utf8.withUnsafeBufferPointer { u8 -> Int32 in
                let cstr = u8.baseAddress.map {
                    UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
                }
                return llama_tokenize(vocab, cstr, Int32(byteCount),
                                      buf.baseAddress, Int32(tokenCapacity),
                                      addBos, false)
            }
        }
        guard count > 0 else { return [] }
        return Array(tokens.prefix(Int(count)))
    }

    private func tokenToPiece(_ token: llama_token) -> [CChar] {
        guard let vocab else { return [] }
        var buffer = [CChar](repeating: 0, count: 32)
        let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            llama_token_to_piece(vocab, token, ptr.baseAddress, 32, 0, false)
        }
        if n >= 0 { return Array(buffer.prefix(Int(n))) }

        // Negative result means "needs this many bytes".
        let needed = Int(-n)
        var big = [CChar](repeating: 0, count: needed)
        let n2 = big.withUnsafeMutableBufferPointer { ptr -> Int32 in
            llama_token_to_piece(vocab, token, ptr.baseAddress, Int32(needed), 0, false)
        }
        return n2 > 0 ? Array(big.prefix(Int(n2))) : []
    }

    /// Decodes a token's bytes into text.
    ///
    /// Returns the RAW text, with control markers intact. Stripping happens at
    /// emit time instead. This ordering matters: stop-sequence detection reads
    /// the accumulated buffer, so stripping earlier would erase the very markers
    /// it looks for and the model would never stop.
    ///
    /// A token's bytes are not necessarily a whole UTF-8 sequence (CJK and emoji
    /// split across tokens), so incomplete bytes are held until they complete.
    private func consumeUTF8(_ piece: [CChar]) -> String {
        transientCChars.append(contentsOf: piece)
        if let s = String(validatingUTF8: transientCChars + [0]) {
            transientCChars.removeAll()
            return s
        }
        // Guard against unbounded growth on genuinely invalid bytes.
        if transientCChars.count > 16 {
            transientCChars.removeFirst()
        }
        return ""
    }

    /// Removes chat-template control markers from generated text.
    ///
    /// Two passes. First the whole well-formed markers, then the fragments that
    /// survive a token boundary — a quantised model often emits `im_end|` on its
    /// own, with the leading `<|` having been a separate token that the streaming
    /// hold already released. Those fragments are invisible to a plain substring
    /// match, which is why they kept reappearing after the stop list was widened.
    static func stripControlTokens(_ text: String) -> String {
        var out = text
        for marker in controlMarkers {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        for fragment in controlFragments where out.contains(fragment) {
            out = out.replacingOccurrences(of: fragment, with: "")
        }
        return out
    }

    /// Written as unicode escapes so the source file stays pure ASCII, which
    /// avoids any chance of editor encoding damage to these literals.
    private static let controlMarkers: [String] = [
        "<\u{007C}im_start\u{007C}>",       // <|im_start|>
        "<\u{007C}im_end\u{007C}>",         // <|im_end|>
        "<\u{007C}endoftext\u{007C}>",      // <|endoftext|>
        "<\u{007C}eot_id\u{007C}>",         // <|eot_id|>
        "<\u{007C}start_header_id\u{007C}>",
        "<\u{007C}end_header_id\u{007C}>",
        "<\u{FF5C}im_start\u{FF5C}>",       // full-width pipe variants
        "<\u{FF5C}im_end\u{FF5C}>",
    ]

    /// Partial marker spellings produced when a marker is split across tokens.
    /// Ordered longest-first so the longer match is removed before its substring.
    private static let controlFragments: [String] = [
        "im_start\u{007C}>",
        "im_end\u{007C}>",
        "endoftext\u{007C}>",
        "eot_id\u{007C}>",
        "start_header_id\u{007C}>",
        "end_header_id\u{007C}>",
        "\u{007C}im_start",
        "\u{007C}im_end",
        "\u{007C}endoftext",
        "\u{007C}eot_id",
        "im_end\u{FF5C}>",
        "im_start\u{FF5C}>",
    ]

    // MARK: Chat template

    /// Applies the model's own chat template.
    ///
    /// Falls back to ChatML only when the model ships no template at all, which
    /// is common for hand-made GGUF conversions. ChatML is not universal, so the
    /// fallback is a guess; when it is wrong the model may echo the markers,
    /// which `stripControlTokens` then removes.
    func chatPrompt(messages: [(role: String, content: String)], addAssistant: Bool) -> String {
        guard let model else { return Self.chatMLPrompt(messages) }

        let template = llama_model_chat_template(model, nil)

        var cMessages: [llama_chat_message] = []
        var storage: [UnsafeMutablePointer<CChar>?] = []
        defer { storage.forEach { if let p = $0 { free(p) } } }

        for m in messages {
            let r = strdup(m.role)
            let c = strdup(m.content)
            storage.append(r)
            storage.append(c)
            cMessages.append(llama_chat_message(role: r, content: c))
        }

        // Read counts before borrowing: touching `.count` inside the closure
        // would be an overlapping (exclusive) access to the same array.
        let messageCount = cMessages.count

        let required = cMessages.withUnsafeMutableBufferPointer { buf -> Int32 in
            llama_chat_apply_template(template, buf.baseAddress, messageCount,
                                      addAssistant, nil, 0)
        }
        guard required > 0 else { return Self.chatMLPrompt(messages) }

        var out = [CChar](repeating: 0, count: Int(required) + 1)
        let capacity = out.count

        let written = cMessages.withUnsafeMutableBufferPointer { buf -> Int32 in
            out.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                llama_chat_apply_template(template, buf.baseAddress, messageCount,
                                          addAssistant, outBuf.baseAddress, Int32(capacity))
            }
        }
        guard written > 0 else { return Self.chatMLPrompt(messages) }
        return String(cString: out)
    }

    /// True when the loaded model ships its own chat template.
    var hasNativeChatTemplate: Bool {
        guard let model else { return false }
        return llama_model_chat_template(model, nil) != nil
    }

    private static func chatMLPrompt(_ messages: [(role: String, content: String)]) -> String {
        var s = ""
        for m in messages {
            s += "<|im_start|>\(m.role)\n\(m.content)<|im_end|>\n"
        }
        return s + "<|im_start|>assistant\n"
    }

    private static func describe(_ m: OpaquePointer) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            llama_model_desc(m, ptr.baseAddress, 256)
        }
        return n > 0 ? String(cString: buf) : "unknown"
    }

    func modelSizeBytes() -> Int64 {
        guard let m = model else { return 0 }
        return Int64(llama_model_size(m))
    }
}
