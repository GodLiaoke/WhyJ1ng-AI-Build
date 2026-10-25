import SwiftUI
import Vision
import CoreML
import AVFoundation
import QuartzCore
import Combine

// MARK: - Detection result
struct Detection: Identifiable, Hashable {
    let id = UUID()
    /// Normalised (0...1) box in the source image, top-left origin.
    var rect: CGRect
    var confidence: Float
    var label: String
    /// Consecutive frames this object has been tracked for.
    var hits: Int = 1
}

// MARK: - Per-frame parameter snapshot

struct DetectionParams {
    let confidence: Float
    let personOnly: Bool
    let minSize: CGFloat
    let nmsIoU: Float
    let requiredFrames: Int
    let inputSize: CGFloat
}

// MARK: - Raw tensor reader
// `MLMultiArray`'s NSNumber subscript boxes every element, which cost roughly
// 1.3M allocations per frame on a (1, 84, 8400) tensor and capped us at ~3fps.
// Reading through a raw pointer with real strides is the single biggest win.

private struct TensorReader {
    enum Kind { case f32, f16, f64, i32, unknown }

    let base: UnsafeRawPointer
    let strideChannel: Int
    let strideAnchor: Int
    let kind: Kind

    @inline(__always)
    func value(_ channel: Int, _ anchor: Int) -> Float {
        let i = channel * strideChannel + anchor * strideAnchor
        switch kind {
        case .f32: return base.assumingMemoryBound(to: Float.self)[i]
        case .f16: return Float(base.assumingMemoryBound(to: Float16.self)[i])
        case .f64: return Float(base.assumingMemoryBound(to: Double.self)[i])
        case .i32: return Float(base.assumingMemoryBound(to: Int32.self)[i])
        case .unknown: return 0
        }
    }
}

// MARK: - YOLO inference
// Loads a Core ML model, runs Vision, decodes the raw (1, 4+classes, N) tensor,
// runs NMS, optionally filters to `person` only, and applies temporal tracking
// so flickering false positives never reach the screen.
final class YOLOViewModel: ObservableObject {

    let settings = DetectorSettings.shared

    @Published var detections: [Detection] = []
    @Published var fps: Double = 0
    @Published var status: String = "未加载模型"
    @Published var errorMessage: String? = nil
    /// Inference time of the last frame, in milliseconds.
    @Published var lastInferenceMs: Double = 0
    @Published var lastDecodeMs: Double = 0
    /// Number of raw candidates before NMS, shown in the debug overlay.
    @Published var rawCount: Int = 0

    private var visionModel: VNCoreMLModel?
    private var cachedRequest: VNCoreMLRequest?
    private let inferQueue = DispatchQueue(label: "yolo.inference", qos: .userInitiated)
    private let stateLock = NSLock()
    private var isBusy = false
    private var smoothedFPS: Double = 0
    private var lastInferenceStart: CFTimeInterval = 0

    /// Input size is read from the model's own image input, not assumed.
    private var inputSize: CGFloat = 640

    /// Resolved once per model: whether tensor coords are normalised or pixels.
    private var coordsAreNormalised: Bool? = nil

    private var tracker = BoxTracker()

    var isReady: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return visionModel != nil
    }

    var modelName: String = ""

    // MARK: Load

    func load(from url: URL) async {
        publish(status: "正在加载模型…", error: nil)
        do {
            let loaded = try await ModelLoader.loadVisionModel(at: url) { [weak self] message in
                self?.publish(status: message, error: nil)
            }
            apply(model: loaded.model, name: url.lastPathComponent, input: loaded.inputSize)
            publish(status: "模型就绪 · \(url.lastPathComponent)", error: nil)
        } catch {
            stateLock.lock(); visionModel = nil; stateLock.unlock()
            publish(status: "加载失败", error: "模型加载失败：\(error.localizedDescription)")
        }
    }

    /// Drops the cached `.mlmodelc` and compiles the source package again.
    func reloadRecompiling(from url: URL) async {
        publish(status: "重新编译模型…", error: nil)
        do {
            let compiled = try await ModelLoader.compiledModelURL(for: url,
                                                                  forceRecompile: true) { [weak self] message in
                self?.publish(status: message, error: nil)
            }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let mlModel = try await MLModel.load(contentsOf: compiled, configuration: config)
            let vm = try VNCoreMLModel(for: mlModel)
            apply(model: vm,
                  name: url.lastPathComponent,
                  input: ModelLoader.imageInputSize(of: mlModel))
            publish(status: "模型就绪 · \(url.lastPathComponent)", error: nil)
        } catch {
            stateLock.lock(); visionModel = nil; stateLock.unlock()
            publish(status: "加载失败", error: "模型加载失败：\(error.localizedDescription)")
        }
    }

    private func apply(model: VNCoreMLModel, name: String, input: CGFloat?) {
        // Build the request once. Rebuilding it per frame re-arms the whole
        // Vision graph and was a measurable part of the 3fps ceiling.
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        request.usesCPUOnly = false

        stateLock.lock()
        visionModel = model
        cachedRequest = request
        modelName = name
        coordsAreNormalised = nil
        if let input { self.inputSize = input }
        stateLock.unlock()
        tracker.reset()
    }

    /// Hop to the main queue; safe from any thread.
    private func publish(status: String, error: String?) {
        let apply = { [weak self] in
            guard let self else { return }
            self.status = status
            if let error { self.errorMessage = error }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    // MARK: Live camera inference

    func detect(pixelBuffer: CVPixelBuffer) {
        // Optional rate cap. Capping frees thermal headroom, which often raises
        // the *sustained* rate above an uncapped run.
        let cap = settings.maxFPS
        if cap > 0 {
            let now = CACurrentMediaTime()
            if now - lastInferenceStart < (1.0 / cap) { return }
            lastInferenceStart = now
        }

        stateLock.lock()
        let request = cachedRequest
        let busy = isBusy
        if request != nil && !busy { isBusy = true }
        stateLock.unlock()
        guard let request, !busy else { return }

        // Snapshot the live settings on the calling (main) thread so the
        // inference queue never touches the observable object.
        let params = DetectionParams(confidence: Float(settings.confidence),
                                     personOnly: settings.personOnly,
                                     minSize: CGFloat(settings.minSize),
                                     nmsIoU: Float(settings.nmsIoU),
                                     requiredFrames: settings.trackingEnabled ? settings.requiredFrames : 1,
                                     inputSize: inputSize)

        let t0 = Date()
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))

        inferQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock(); self.isBusy = false; self.stateLock.unlock()
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: .up,
                                                options: [:])
            var raw: [Detection] = []
            do {
                try handler.perform([request])
                raw = self.decode(request: request, imageSize: imageSize, params: params)
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }

            let tInfer = Date()
            var final = self.nms(raw, iou: params.nmsIoU)
            final = self.tracker.stabilise(final, requiredFrames: params.requiredFrames)
            let tEnd = Date()

            let inferMs = tInfer.timeIntervalSince(t0) * 1000
            let decodeMs = tEnd.timeIntervalSince(tInfer) * 1000
            let rawCount = raw.count

            DispatchQueue.main.async {
                self.detections = final
                self.rawCount = rawCount
                self.lastInferenceMs = inferMs
                self.lastDecodeMs = decodeMs
                let fpsNow = 1.0 / max(tEnd.timeIntervalSince(t0), 0.0001)
                self.smoothedFPS = self.smoothedFPS == 0
                    ? fpsNow
                    : (self.smoothedFPS * 0.8 + fpsNow * 0.2)
                self.fps = self.smoothedFPS
                // Feed the chat module's detection history. Done here, on the
                // main actor, so the store's published state stays consistent.
                DetectionStore.shared.record(detections: final, source: "camera")
            }
        }
    }

    // MARK: Still image inference

    /// Runs detection on a still image (photo library or captured screen).
    /// No temporal tracking: a single image has no "previous frame".
    /// Inference runs off the main thread so the UI stays responsive.
    func detectImage(_ image: UIImage) async -> [Detection] {
        guard let cgImage = image.cgImage else { return [] }
        let params = snapshotParams()
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)

        stateLock.lock()
        let request = cachedRequest
        stateLock.unlock()
        guard let request else { return [] }

        return await withCheckedContinuation { continuation in
            inferQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
                let handler = VNImageRequestHandler(cgImage: cgImage,
                                                    orientation: .up,
                                                    options: [:])
                var raw: [Detection] = []
                do {
                    try handler.perform([request])
                    raw = self.decode(request: request, imageSize: imageSize, params: params)
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async { self.errorMessage = message }
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: self.nms(raw, iou: params.nmsIoU))
            }
        }
    }

    private func snapshotParams() -> DetectionParams {
        DetectionParams(confidence: Float(settings.confidence),
                        personOnly: settings.personOnly,
                        minSize: CGFloat(settings.minSize),
                        nmsIoU: Float(settings.nmsIoU),
                        requiredFrames: 1,
                        inputSize: inputSize)
    }

    // MARK: Decode

    private func decode(request: VNCoreMLRequest,
                        imageSize: CGSize,
                        params: DetectionParams) -> [Detection] {
        var out: [Detection] = []

        // Path A: model already carries NMS -> Vision returns object observations.
        if let objs = request.results as? [VNRecognizedObjectObservation] {
            for o in objs {
                guard let top = o.labels.first, top.confidence >= params.confidence else { continue }
                if params.personOnly && top.identifier != "person" { continue }
                let b = o.boundingBox // Vision space: bottom-left origin, normalised
                let rect = CGRect(x: b.origin.x,
                                  y: 1 - b.origin.y - b.size.height,
                                  width: b.size.width,
                                  height: b.size.height)
                if accept(rect, params: params) {
                    out.append(Detection(rect: rect, confidence: top.confidence, label: top.identifier))
                }
            }
            return out
        }

        // Path B: raw Ultralytics tensor, shape (1, 4+classes, N) or (1, N, 4+classes).
        if let feats = request.results as? [VNCoreMLFeatureValueObservation] {
            for f in feats {
                guard let arr = f.featureValue.multiArrayValue else { continue }
                out.append(contentsOf: decodeTensor(arr, imageSize: imageSize, params: params))
            }
        }
        return out
    }

    private func decodeTensor(_ arr: MLMultiArray,
                              imageSize: CGSize,
                              params: DetectionParams) -> [Detection] {
        let shape = arr.shape.map { $0.intValue }
        guard shape.count >= 2 else { return [] }

        var channels = 0, count = 0, transposed = false
        if shape.count >= 3 {
            if shape[1] < shape[2] {
                channels = shape[1]; count = shape[2]; transposed = false   // (1, C, N)
            } else {
                channels = shape[2]; count = shape[1]; transposed = true    // (1, N, C)
            }
        } else {
            channels = shape[1]; count = 1
        }
        guard channels >= 5, count > 0 else { return [] }

        let classCount = channels - 4
        let inputSize = params.inputSize

        // Raw pointer + real strides. This replaces ~1.3M NSNumber boxes/frame.
        let strides = arr.strides.map { $0.intValue }
        let kind: TensorReader.Kind
        switch arr.dataType {
        case .float32: kind = .f32
        case .float16: kind = .f16
        case .double: kind = .f64
        case .int32: kind = .i32
        @unknown default: kind = .unknown
        }
        guard kind != .unknown else { return [] }

        let reader = TensorReader(base: UnsafeRawPointer(arr.dataPointer),
                                  strideChannel: transposed ? strides[2] : strides[1],
                                  strideAnchor: transposed ? strides[1] : strides[2],
                                  kind: kind)

        // Vision .scaleFit letterboxes the frame into the square model input.
        let W = imageSize.width, H = imageSize.height
        guard W > 0, H > 0 else { return [] }
        let scale = min(inputSize / W, inputSize / H)
        let visW = W * scale, visH = H * scale
        guard visW > 0, visH > 0 else { return [] }
        let offX = (inputSize - visW) / 2.0
        let offY = (inputSize - visH) / 2.0

        // Decide units once per model, not per box. Sample across the batch so
        // a single stray value cannot flip the whole frame's scale.
        if coordsAreNormalised == nil {
            var peak: Float = 0
            let samples = [0, count / 4, count / 2, (count * 3) / 4, max(count - 1, 0)]
            for n in samples where n >= 0 && n < count {
                for c in 0..<4 {
                    peak = max(peak, abs(reader.value(c, n)))
                }
            }
            let normalised = peak <= 2.0
            stateLock.lock()
            coordsAreNormalised = normalised
            stateLock.unlock()
        }
        let unit: CGFloat = (coordsAreNormalised ?? true) ? inputSize : 1.0

        let threshold = params.confidence
        let personOnly = params.personOnly
        var out: [Detection] = []
        out.reserveCapacity(32)

        for n in 0..<count {
            // Pick the best class for this anchor, then reject by threshold.
            // With pointer access this inner loop is cheap; the writes below
            // only happen for anchors that pass.
            var bestClass = 0
            var bestScore: Float = 0
            for c in 0..<classCount {
                let s = reader.value(4 + c, n)
                if s > bestScore { bestScore = s; bestClass = c }
            }
            guard bestScore >= threshold else { continue }
            if personOnly && bestClass != 0 { continue }

            let cx = CGFloat(reader.value(0, n)) * unit
            let cy = CGFloat(reader.value(1, n)) * unit
            let bw = CGFloat(reader.value(2, n)) * unit
            let bh = CGFloat(reader.value(3, n)) * unit

            // Undo the letterbox, then normalise against the full source image.
            let nx = (cx - offX) / visW
            let ny = (cy - offY) / visH
            let nw = bw / visW
            let nh = bh / visH

            var rect = CGRect(x: nx - nw / 2, y: ny - nh / 2, width: nw, height: nh)
            rect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard accept(rect, params: params) else { continue }

            let label = personOnly ? "person" : Self.cocoName(bestClass)
            out.append(Detection(rect: rect, confidence: bestScore, label: label))
        }
        return out
    }

    /// Rejects degenerate and too-small boxes.
    private func accept(_ rect: CGRect, params: DetectionParams) -> Bool {
        guard rect.width > 0.005, rect.height > 0.005 else { return false }
        let shorter = min(rect.width, rect.height)
        guard shorter >= params.minSize else { return false }
        return true
    }

    /// COCO class names, in the order Ultralytics exports them.
    static func cocoName(_ index: Int) -> String {
        guard index >= 0 && index < cocoNames.count else { return "obj \(index)" }
        return cocoNames[index]
    }

    /// COCO class names, in the order Ultralytics exports them.
    /// Exposed so the detail card can map a label back to its class index.
    static let cocoNames: [String] = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train",
        "truck", "boat", "traffic light", "fire hydrant", "stop sign",
        "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
        "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag",
        "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite",
        "baseball bat", "baseball glove", "skateboard", "surfboard",
        "tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon",
        "bowl", "banana", "apple", "sandwich", "orange", "broccoli", "carrot",
        "hot dog", "pizza", "donut", "cake", "chair", "couch", "potted plant",
        "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote",
        "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
        "refrigerator", "book", "clock", "vase", "scissors", "teddy bear",
        "hair drier", "toothbrush"
    ]

    // MARK: NMS

    private func nms(_ boxes: [Detection], iou: Float) -> [Detection] {
        let sorted = boxes.sorted { $0.confidence > $1.confidence }
        var kept: [Detection] = []
        for b in sorted {
            var keep = true
            for k in kept where iouOf(b.rect, k.rect) > iou {
                keep = false
                break
            }
            if keep { kept.append(b) }
        }
        return kept
    }

    private func iouOf(_ a: CGRect, _ b: CGRect) -> Float {
        let ix = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let iy = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let inter = ix * iy
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? Float(inter / union) : 0
    }
}

// MARK: - Temporal tracker
// Greedy IoU association across frames. A detection must persist for
// `requiredFrames` consecutive frames before it is shown, which removes the
// one-frame false positives (blankets, curtains, pillows) while real people
// stay visible continuously.

struct BoxTracker {
    private struct Track {
        var rect: CGRect
        var confidence: Float
        var label: String
        var hits: Int
        var misses: Int
    }

    private var tracks: [Track] = []
    private let iouMatch: Float = 0.30
    private let maxMisses = 6

    mutating func reset() {
        tracks.removeAll()
    }

    mutating func stabilise(_ detections: [Detection], requiredFrames: Int) -> [Detection] {
        let need = max(1, requiredFrames)
        var unmatched = Array(tracks.indices)

        var output: [Detection] = []
        var next: [Track] = []

        for det in detections {
            var bestIdx: Int? = nil
            var bestIoU: Float = 0
            for i in unmatched {
                let score = iou(det.rect, tracks[i].rect)
                if score > bestIoU {
                    bestIoU = score
                    bestIdx = i
                }
            }

            if let idx = bestIdx, bestIoU >= iouMatch {
                unmatched.removeAll { $0 == idx }
                let t = tracks[idx]
                let merged = Track(rect: det.rect,
                                   confidence: det.confidence,
                                   label: det.label,
                                   hits: t.hits + 1,
                                   misses: 0)
                next.append(merged)
                if merged.hits >= need {
                    output.append(Detection(rect: merged.rect,
                                            confidence: merged.confidence,
                                            label: merged.label,
                                            hits: merged.hits))
                }
            } else {
                next.append(Track(rect: det.rect,
                                  confidence: det.confidence,
                                  label: det.label,
                                  hits: 1,
                                  misses: 0))
                if need <= 1 {
                    output.append(Detection(rect: det.rect,
                                            confidence: det.confidence,
                                            label: det.label,
                                            hits: 1))
                }
            }
        }

        // Age out tracks that were not matched this frame.
        for i in unmatched {
            var t = tracks[i]
            t.misses += 1
            if t.misses <= maxMisses {
                next.append(t)
                // Keep showing a briefly-occluded object.
                if t.hits >= need {
                    output.append(Detection(rect: t.rect,
                                            confidence: t.confidence,
                                            label: t.label,
                                            hits: t.hits))
                }
            }
        }

        tracks = next
        return output
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let ix = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let iy = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let inter = ix * iy
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? Float(inter / union) : 0
    }
}
