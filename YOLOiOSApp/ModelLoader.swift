import Foundation
import CoreML
import Vision
import UniformTypeIdentifiers
import SwiftUI
import UIKit

// MARK: - Model item presented in the UI
struct ModelItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let byteSize: Int64
    let isBundled: Bool

    var sizeText: String {
        let mb = Double(byteSize) / 1_048_576.0
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(byteSize) / 1024.0
        return String(format: "%.0f KB", kb)
    }

    /// `.mlmodelc` is already compiled; everything else needs a compile pass.
    var isCompiled: Bool {
        url.pathExtension.lowercased() == "mlmodelc"
    }

    /// Known YOLO families, used to show an accuracy/speed hint in the picker.
    var tier: ModelTier {
        let n = name.lowercased()
        if n.contains("yolo11l") || n.contains("yolo11x") || n.contains("yolov8l") || n.contains("yolov8x") {
            return ModelTier(label: "最高精度", detail: "最准，帧率较低", rank: 0, tint: Palette.success)
        }
        if n.contains("yolo11m") || n.contains("yolov8m") {
            return ModelTier(label: "高精度", detail: "精度好，速度可接受", rank: 1, tint: Palette.accent)
        }
        if n.contains("yolo11s") || n.contains("yolov8s") {
            return ModelTier(label: "推荐", detail: "精度与速度平衡", rank: 2, tint: Palette.accent)
        }
        if n.contains("yolo11n") || n.contains("yolov8n") {
            return ModelTier(label: "最快", detail: "最省电，误报偏多", rank: 3, tint: Palette.warning)
        }
        return ModelTier(label: "自定义", detail: "非标准命名", rank: 4, tint: Palette.inkTertiary)
    }
}

struct ModelTier {
    let label: String
    let detail: String
    let rank: Int
    let tint: Color
}

// MARK: - Model loader
// Three sources, checked in this order:
//   1. files the user dropped into the app folder (visible in the Files app)
//   2. models imported through the document picker  -> Documents/Models
//   3. a model bundled into the app itself
enum ModelLoader {

    static let modelExtensions = ["mlpackage", "mlmodel", "mlmodelc"]

    // MARK: Locations

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var modelsDir: URL {
        let dir = documentsURL.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Folder the user sees in Files.app -> On My iPhone -> AppBrand.filesFolder
    static var inboxURL: URL {
        let dir = documentsURL.appendingPathComponent("Put Models Here", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where compiled `.mlmodelc` products are cached between launches.
    static var compiledCacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CompiledModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Discovery

    private static func isModel(_ url: URL) -> Bool {
        modelExtensions.contains(url.pathExtension.lowercased())
    }

    private static func byteSize(of url: URL) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue {
            guard let e = fm.enumerator(at: url,
                                        includingPropertiesForKeys: [.fileSizeKey],
                                        options: [.skipsHiddenFiles]) else { return 0 }
            for case let f as URL in e {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey])
                total += Int64(v?.fileSize ?? 0)
            }
        } else {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey])
            total = Int64(v?.fileSize ?? 0)
        }
        return total
    }

    /// Recursively scans a directory for Core ML models.
    private static func scan(_ root: URL, depth: Int = 3) -> [ModelItem] {
        guard depth >= 0 else { return [] }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var found: [ModelItem] = []
        for child in children {
            if isModel(child) {
                found.append(ModelItem(id: child.path,
                                       url: child,
                                       name: child.lastPathComponent,
                                       byteSize: byteSize(of: child),
                                       isBundled: false))
                continue
            }
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                found.append(contentsOf: scan(child, depth: depth - 1))
            }
        }
        return found
    }

    /// All models currently reachable on this device.
    static func discoverModels() -> [ModelItem] {
        var items: [ModelItem] = []
        var seen = Set<String>()

        for item in scan(documentsURL) {
            // Prefer the compiled product when both forms are present: it skips
            // the first-run compile entirely.
            let key = (item.name as NSString).deletingPathExtension
            if let existing = items.firstIndex(where: {
                ($0.name as NSString).deletingPathExtension == key
            }) {
                if item.isCompiled && !items[existing].isCompiled {
                    items[existing] = item
                }
                continue
            }
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            items.append(item)
        }

        // Models shipped inside the app bundle (any recognized name).
        if let bundleURL = Bundle.main.resourceURL,
           let entries = try? FileManager.default.contentsOfDirectory(
               at: bundleURL,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]) {
            for entry in entries where isModel(entry) {
                let key = (entry.lastPathComponent as NSString).deletingPathExtension
                if seen.contains(key) { continue }
                seen.insert(key)
                items.append(ModelItem(id: entry.path,
                                       url: entry,
                                       name: entry.lastPathComponent,
                                       byteSize: byteSize(of: entry),
                                       isBundled: true))
            }
        }

        // Most accurate first, bundled last so a dropped-in model wins.
        return items.sorted { a, b in
            if a.tier.rank != b.tier.rank { return a.tier.rank < b.tier.rank }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The most accurate model available, used as the initial selection.
    static func bestModel() -> ModelItem? {
        discoverModels().first
    }

    // MARK: Import

    /// Copies a model chosen in the document picker into the app sandbox.
    @discardableResult
    static func importModel(from url: URL) throws -> URL {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let dest = modelsDir.appendingPathComponent(url.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: url, to: dest)
        return dest
    }

    // MARK: Compile + load

    /// Cache key built from name + size + mtime so the compiled product is
    /// reused until the source package actually changes.
    private static func cacheKey(for url: URL) -> String {
        let size = byteSize(of: url)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let raw = "\(base)_\(size)_\(Int(mtime))"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return raw.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }

    /// Returns a loadable `.mlmodelc`, compiling the source package if needed.
    /// Compilation is blocking and can take several seconds, so it always runs
    /// on a background queue.
    static func compiledModelURL(for url: URL,
                                 forceRecompile: Bool = false,
                                 status: ((String) -> Void)? = nil) async throws -> URL {
        // Already compiled -> load straight away.
        if url.pathExtension.lowercased() == "mlmodelc" {
            return url
        }

        let fm = FileManager.default
        let baseName = (url.lastPathComponent as NSString).deletingPathExtension
        let destDir = compiledCacheDir.appendingPathComponent(cacheKey(for: url), isDirectory: true)
        let destModel = destDir.appendingPathComponent(baseName + ".mlmodelc", isDirectory: true)

        if !forceRecompile, fm.fileExists(atPath: destModel.path) {
            status?("使用已编译模型…")
            return destModel
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    status?("正在编译模型（首次较慢）…")
                    let compiled = try MLModel.compileModel(at: url)

                    try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: destModel.path) {
                        try? fm.removeItem(at: destModel)
                    }
                    do {
                        try fm.copyItem(at: compiled, to: destModel)
                        status?("编译完成，正在载入…")
                        continuation.resume(returning: destModel)
                    } catch {
                        // Cache write failed but we still have a usable temp product.
                        status?("编译完成（未缓存），正在载入…")
                        continuation.resume(returning: compiled)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Square image input size of a loaded model, used to undo Vision's
    /// `.scaleFit` letterboxing. Falls back to 640 when the model has no image
    /// input (e.g. an already-`VNRecognizedObjectObservation` model).
    static func imageInputSize(of mlModel: MLModel) -> CGFloat? {
        let inputs = mlModel.modelDescription.inputDescriptionsByName
        guard let desc = inputs.first(where: { $0.value.type == .image })?.value,
              let constraint = desc.imageConstraint else { return nil }
        let w = CGFloat(constraint.pixelsWide)
        let h = CGFloat(constraint.pixelsHigh)
        guard w > 0, h > 0 else { return nil }
        return max(w, h)
    }

    /// Compiles (if needed) then loads the model and wraps it for Vision.
    /// Also returns the model's square image input size, which the decoder needs
    /// to undo Vision's `.scaleFit` letterboxing.
    static func loadVisionModel(at url: URL,
                                status: ((String) -> Void)? = nil) async throws -> (model: VNCoreMLModel, inputSize: CGFloat) {
        let compiled = try await compiledModelURL(for: url, status: status)
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let mlModel = try await MLModel.load(contentsOf: compiled, configuration: config)
        let vm = try VNCoreMLModel(for: mlModel)
        return (vm, imageInputSize(of: mlModel) ?? 640)
    }

    // MARK: Picker types

    /// Broad set of types so the picker lets the user reach a .mlpackage folder.
    static var pickerTypes: [UTType] {
        var types: [UTType] = []
        if let pkg = UTType(filenameExtension: "mlpackage", conformingTo: .package) { types.append(pkg) }
        if let mdl = UTType(filenameExtension: "mlmodel", conformingTo: .data) { types.append(mdl) }
        types.append(contentsOf: [.package, .folder, .item, .data, .content])
        return types
    }
}

// MARK: - Document picker (SwiftUI wrapper)

struct ModelPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: ModelLoader.pickerTypes,
                                                    asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
