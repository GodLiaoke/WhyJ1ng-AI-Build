import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Photo detection
// Pick a photo (or take one) and run the current model over it. Results are
// drawn over the image with a full-resolution coordinate mapping, so this also
// doubles as a way to sanity-check the camera pipeline's box placement.

struct PhotoDetectView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: YOLOViewModel
    @ObservedObject private var settings = DetectorSettings.shared
    @Environment(\.dismiss) private var dismiss

    /// Presents the album picker on iOS 15. On iOS 16+ the album button is a
    /// `PhotosPicker` that presents its own sheet, so this stays false there.
    @State private var showAlbumSheet = false
    /// The untouched image as picked. Adjustments are always applied from this,
    /// never from an already-adjusted copy, otherwise dragging a slider twice
    /// compounds the correction instead of replacing it.
    @State private var sourceImage: UIImage? = nil
    /// What is shown and detected on: sourceImage plus the current adjustments.
    @State private var image: UIImage? = nil
    @State private var detections: [Detection] = []
    @State private var running = false
    @State private var errorText: String? = nil
    @State private var elapsedMs: Double = 0
    @State private var showCamera = false
    @State private var brightness: Double = 0
    @State private var contrast: Double = 1
    @State private var saturation: Double = 1
    @State private var savedNotice: String? = nil
    /// Debounces slider drags so a full re-detect does not run on every tick.
    @State private var reprocessWork: DispatchWorkItem? = nil

    var body: some View {
        NavigationView {
            ZStack {
                Palette.canvas.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: DS.Space.l) {

                        imageArea

                        if let errorText {
                            SurfaceCard(padding: DS.Space.l) {
                                HStack(spacing: DS.Space.s) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(Palette.danger)
                                    Text(errorText)
                                        .font(DS.Font.callout)
                                        .foregroundColor(Palette.danger)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        if image != nil {
                            PhotoExportControls(brightness: $brightness,
                                                contrast: $contrast,
                                                saturation: $saturation) {
                                scheduleReprocess()
                            }
                            // Sliders must re-run detection too, not just the
                            // preset chips: previously only the chips did, so the
                            // adjustment looked like it had no effect.
                            .onChangeCompat(of: brightness) { _, _ in scheduleReprocess() }
                            .onChangeCompat(of: contrast) { _, _ in scheduleReprocess() }
                            .onChangeCompat(of: saturation) { _, _ in scheduleReprocess() }
                        }

                        actions

                        resultSummary

                        Color.clear.frame(height: DS.Space.xl)
                    }
                    .padding(DS.Space.l)
                }
            }
            .navigationTitle("图片识别")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showCamera) {
                PhotoPickerFallback { picked in
                    Task { await run(picked) }
                }
            }
            .onAppear {
                Task { await ensureModel() }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: Image + overlay

    private var imageArea: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "图片", systemImage: "photo")

            SurfaceCard(padding: DS.Space.m) {
                ZStack {
                    if let image {
                        GeometryReader { geo in
                            let fitted = aspectFit(image.size, in: geo.size)
                            ZStack(alignment: .topLeading) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: geo.size.width, height: geo.size.height)

                                ForEach(detections) { d in
                                    let w = d.rect.width * fitted.width
                                    let h = d.rect.height * fitted.height
                                    let x = fitted.minX + d.rect.minX * fitted.width
                                    let y = fitted.minY + d.rect.minY * fitted.height
                                    ZStack(alignment: .topLeading) {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(d.label == "person" ? Palette.success : Palette.accent,
                                                    lineWidth: 2)
                                        Text("\(d.label) \(Int(d.confidence * 100))%")
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(d.label == "person"
                                                                       ? Palette.success
                                                                       : Palette.accent))
                                            .offset(y: -18)
                                    }
                                    .frame(width: max(w, 2), height: max(h, 2))
                                    .offset(x: x, y: y)
                                }
                            }
                        }
                        .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
                    } else {
                        EmptyState(systemImage: "photo.on.rectangle.angled",
                                   title: "还没有选择图片",
                                   message: "从相册选一张，或直接拍一张，然后运行检测。")
                            .frame(height: 220)
                    }

                    if running {
                        ZStack {
                            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                                .fill(Color.black.opacity(0.35))
                            VStack(spacing: DS.Space.s) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("识别中…")
                                    .font(DS.Font.caption)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Album entry point

    /// Album entry point.
    ///
    /// iOS 16+ keeps the system `PhotosPicker` untouched. iOS 15 gets
    /// `PHPickerViewController` — the same out-of-process picker that
    /// `PhotosPicker` wraps — so the capability set is identical on both: pick
    /// from the library, no full-library permission prompt, the picked image
    /// arrives as a `UIImage` and feeds the existing detection path.
    @ViewBuilder
    private var albumButton: some View {
        if #available(iOS 16.0, *) {
            ModernAlbumPickerButton(onPicked: { applyPicked($0) }) {
                albumButtonLabel
            }
            .disabled(running)
        } else {
            Button {
                showAlbumSheet = true
            } label: {
                albumButtonLabel
            }
            .buttonStyle(.plain)
            .disabled(running)
            .sheet(isPresented: $showAlbumSheet) {
                LegacyPhotoPicker(onPicked: { picked in
                    showAlbumSheet = false
                    applyPicked(picked)
                }, onCancel: {
                    showAlbumSheet = false
                })
            }
        }
    }

    /// Shared button face, so both pickers look the same.
    private var albumButtonLabel: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "photo.stack")
                .font(.system(size: 15, weight: .semibold))
            Text("从相册选择")
                .font(DS.Font.headline)
            Spacer()
            if running { ProgressView().scaleEffect(0.8) }
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .padding(.horizontal, DS.Space.m)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(Palette.accent)
        )
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "操作", systemImage: "square.and.arrow.down")

            albumButton

            SecondaryButton(title: "相机拍摄一张",
                            systemImage: "camera") {
                showCamera = true
            }

            SecondaryButton(title: "重新运行检测",
                            systemImage: "arrow.clockwise",
                            loading: running) {
                // Always re-detect from the pristine source, so repeated runs
                // with the same sliders give the same result instead of
                // compounding the adjustment.
                guard let source = sourceImage else { return }
                Task { await run(source) }
            }
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var resultSummary: some View {
        if image != nil {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                SectionHeader(title: "结果", systemImage: "list.bullet.rectangle")

                SurfaceCard(padding: DS.Space.l) {
                    VStack(spacing: DS.Space.m) {
                        InfoRow(label: "检出目标", value: "\(detections.count) 个")
                        Hairline()
                        InfoRow(label: "其中人",
                                value: "\(detections.filter { $0.label == "person" }.count) 个")
                        Hairline()
                        InfoRow(label: "耗时", value: String(format: "%.0f ms", elapsedMs), mono: true)
                        Hairline()
                        InfoRow(label: "使用模型", value: engine.modelName.isEmpty ? "—" : engine.modelName)

                        if !detections.isEmpty {
                            Hairline()
                            PrimaryButton(title: "保存标注图到相册",
                                          systemImage: "square.and.arrow.down") {
                                Task { await saveAnnotated() }
                            }
                        }

                        if let savedNotice {
                            Hairline()
                            HStack(spacing: DS.Space.s) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(savedNotice)
                                    .font(DS.Font.caption)
                            }
                            .foregroundColor(Palette.success)
                        }
                    }
                }

                if detections.isEmpty && !running {
                    SurfaceCard(padding: DS.Space.l) {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Text("没有检出目标")
                                .font(DS.Font.headline)
                                .foregroundColor(Palette.ink)
                            Text("试试在「检测调参」里把置信度降到 0.30，或关闭「只检测人」看看模型识别到了什么。")
                                .font(DS.Font.caption)
                                .foregroundColor(Palette.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: Logic

    private func aspectFit(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2,
                      y: (bounds.height - h) / 2,
                      width: w,
                      height: h)
    }

    private func ensureModel() async {
        guard !engine.isReady else { return }
        if let model = app.selectedModel {
            await engine.load(from: model.url)
        } else if let best = ModelLoader.bestModel() {
            await engine.load(from: best.url)
        }
        if !engine.isReady {
            errorText = engine.errorMessage
        }
    }
    /// Single entry point for both pickers: remember the pristine image, reset
    /// the adjustments, then detect. `nil` means the picked item could not be
    /// decoded, which is the only failure either picker can report.
    private func applyPicked(_ picked: UIImage?) {
        guard let picked else {
            errorText = "无法读取所选图片"
            return
        }
        // Remember the pristine image: every adjustment pass starts from it.
        sourceImage = picked
        brightness = 0
        contrast = 1
        saturation = 1
        Task { await run(picked) }
    }

    /// Runs detection on the source image with the current adjustments applied.
    ///
    /// Adjustments are always recomputed from `sourceImage`, so changing a slider
    /// replaces the correction rather than stacking on top of the last one.
    private func run(_ picked: UIImage) async {
        running = true
        errorText = nil
        detections = []
        savedNotice = nil

        let adjusted = PhotoAdjuster.apply(to: picked,
                                           brightness: brightness,
                                           contrast: contrast,
                                           saturation: saturation) ?? picked
        image = adjusted

        await ensureModel()
        guard engine.isReady else {
            errorText = engine.errorMessage ?? "模型不可用"
            running = false
            return
        }

        let t0 = Date()
        let found = await engine.detectImage(adjusted)
        elapsedMs = Date().timeIntervalSince(t0) * 1000
        detections = found
        running = false
    }

    /// Coalesces rapid slider changes into one detection pass.
    private func scheduleReprocess() {
        guard let source = sourceImage else { return }
        reprocessWork?.cancel()
        let work = DispatchWorkItem {
            Task { await run(source) }
        }
        reprocessWork = work
        // A slider emits a value per frame; 250ms keeps the UI responsive while
        // still feeling immediate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Renders the image with its boxes and writes it to the photo library.
    private func saveAnnotated() async {
        guard let base = image else { return }
        // Draw at native resolution so the result is not limited by the preview.
        let size = base.size
        let renderer = UIGraphicsImageRenderer(size: size, format: base.imageRendererFormat)
        let annotated = renderer.image { ctx in
            base.draw(at: .zero)

            for d in detections {
                let rect = CGRect(x: d.rect.minX * size.width,
                                  y: d.rect.minY * size.height,
                                  width: d.rect.width * size.width,
                                  height: d.rect.height * size.height)
                let tint = d.label == "person" ? UIColor.systemGreen : UIColor.systemBlue
                let path = UIBezierPath(roundedRect: rect,
                                        byRoundingCorners: .allCorners,
                                        cornerRadii: CGSize(width: 8, height: 8))
                tint.setStroke()
                path.lineWidth = max(2, size.width / 400)
                path.stroke()

                let label = "\(d.label) \(Int(d.confidence * 100))%"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: max(12, size.width / 60), weight: .bold),
                    .foregroundColor: UIColor.white,
                ]
                let str = NSAttributedString(string: label, attributes: attrs)
                let bounds = str.boundingRect(with: CGSize(width: size.width, height: 60),
                                              options: .usesLineFragmentOrigin, context: nil)
                let chipRect = CGRect(x: rect.minX,
                                      y: rect.minY - bounds.height - 8,
                                      width: bounds.width + 12,
                                      height: bounds.height + 8)
                let chip = UIBezierPath(roundedRect: chipRect, cornerRadius: chipRect.height / 2)
                tint.setFill()
                chip.fill()
                str.draw(at: CGPoint(x: chipRect.minX + 6, y: chipRect.minY + 4))
            }
        }

        do {
            try await PhotoSaver.save(annotated)
            savedNotice = "已保存到相册"
        } catch {
            savedNotice = nil
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Camera capture fallback

struct PhotoPickerFallback: UIViewControllerRepresentable {
    var onPicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPicked: (UIImage) -> Void
        init(onPicked: @escaping (UIImage) -> Void) { self.onPicked = onPicked }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { onPicked(img) }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Album picker, iOS 16+

/// `PhotosPicker` and `PhotosPickerItem` are iOS 16, so they live inside an
/// `@available` type of their own: nothing iOS-16-only leaks into the screen
/// that has to compile for iOS 15, and the iOS 16+ path stays the plain system
/// picker rather than a re-implementation.
@available(iOS 16.0, *)
struct ModernAlbumPickerButton<Label: View>: View {
    /// `nil` when the transferable could not be decoded.
    let onPicked: (UIImage?) -> Void
    @ViewBuilder var label: () -> Label

    @State private var item: PhotosPickerItem? = nil

    var body: some View {
        // Single selection: `maxSelectionCount` only applies to the multi-select
        // overload, and passing it here made the compiler expect a
        // `Binding<[PhotosPickerItem]>` instead.
        PhotosPicker(selection: $item,
                     matching: .images,
                     photoLibrary: .shared()) {
            label()
        }
        // `.task(id:)` instead of `onChange`: it exists on iOS 15 and needs no
        // availability branch of its own.
        .task(id: item) {
            // Shadowing under a different name: `guard let item` would rebind
            // the property to a `let`, and the reset below then fails to compile.
            guard let picked = item else { return }
            let data = try? await picked.loadTransferable(type: Data.self)
            let image = data.flatMap { UIImage(data: $0) }
            onPicked(image)
            // Clearing lets the same photo be picked again in the same session.
            item = nil
        }
    }
}

// MARK: - Album picker, iOS 15

/// Album sheet for iOS 15, where `PhotosPicker` does not exist.
///
/// `PHPickerViewController` needs no `NSPhotoLibraryUsageDescription` prompt
/// (it runs out of process and hands back only what the user tapped), which is
/// the same privacy behaviour the iOS 16+ `PhotosPicker` path has.
struct LegacyPhotoPicker: UIViewControllerRepresentable {
    /// `nil` when the picked item could not be decoded.
    var onPicked: (UIImage?) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        // One image per pick, same as the iOS 16+ single-item binding.
        config.selectionLimit = 1
        // Never re-encode: detection runs on the pixels the user picked.
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: LegacyPhotoPicker

        init(_ parent: LegacyPhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Dismissal is driven by the presenting SwiftUI sheet, not by the
            // view controller: inside a sheet this controller is a child, so
            // `dismiss(animated:)` on it would be a no-op.
            guard let result = results.first else {
                parent.onCancel()
                return
            }
            let provider = result.itemProvider
            guard provider.canLoadObject(ofClass: UIImage.self) else {
                parent.onPicked(nil)
                return
            }
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                DispatchQueue.main.async { self.parent.onPicked(image) }
            }
        }
    }
}
