import SwiftUI
import AVFoundation
import CoreVideo

// MARK: - Live detection screen

struct CameraView: View {
    @EnvironmentObject private var app: AppState
    /// Shared engine: same instance the photo screen and overlay use.
    @EnvironmentObject private var yolo: YOLOViewModel
    @StateObject private var camera = CameraManager()
    @ObservedObject private var settings = DetectorSettings.shared
    @State private var frameAspect: CGFloat = 3.0 / 4.0
    @State private var showSettings = false
    /// Box currently being inspected via tap.
    @State private var selectedBox: Detection? = nil

    private func boxColor(_ d: Detection, selected: Bool) -> Color {
        if selected { return Palette.warning }
        return d.label == "person" ? Palette.success : Palette.accent
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Camera preview, videoGravity = .resizeAspectFill
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            // Detection boxes mapped through the same aspect-fill transform
            GeometryReader { geo in
                let box = fillRect(viewSize: geo.size)
                ForEach(yolo.detections) { d in
                    let w = d.rect.width * box.width
                    let h = d.rect.height * box.height
                    let x = box.minX + d.rect.minX * box.width
                    let y = box.minY + d.rect.minY * box.height
                    let isSelected = selectedBox?.id == d.id

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(boxColor(d, selected: isSelected),
                                    lineWidth: isSelected ? 3 : 2.5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(boxColor(d, selected: isSelected).opacity(isSelected ? 0.20 : 0.10))
                            )
                        Text("\(d.label) \(Int(d.confidence * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(boxColor(d, selected: isSelected)))
                            .offset(y: -22)
                    }
                    .frame(width: max(w, 2), height: max(h, 2))
                    .offset(x: x, y: y)
                    .animation(DS.Motion.quick, value: d.rect)
                    // Tap a box to inspect it. Only active when the user has
                    // enabled it, so the rest of the screen stays untouchable
                    // and the preview keeps its own gestures.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard settings.boxTapDetails else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(DS.Motion.spring) {
                            selectedBox = isSelected ? nil : d
                        }
                    }
                    .allowsHitTesting(settings.boxTapDetails)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(settings.boxTapDetails)

            // Detail card for the tapped box
            if settings.boxTapDetails, let sel = selectedBox {
                VStack {
                    Spacer()
                    DetectionDetailCard(detection: sel,
                                        frameAspect: frameAspect,
                                        onClose: {
                                            withAnimation(DS.Motion.spring) { selectedBox = nil }
                                        })
                        .padding(.horizontal, DS.Space.l)
                        .padding(.bottom, 190)   // clear the bottom status pills
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(true)
            }

            // Chrome
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
        }
        .statusBarHidden(false)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            camera.onFrame = { pb in
                let w = CGFloat(CVPixelBufferGetWidth(pb))
                let h = CGFloat(CVPixelBufferGetHeight(pb))
                if w > 0, h > 0 {
                    let aspect = w / h
                    if abs(aspect - frameAspect) > 0.001 {
                        DispatchQueue.main.async { frameAspect = aspect }
                    }
                }
                yolo.detect(pixelBuffer: pb)
            }
            camera.start()
        }
        .onDisappear {
            camera.onFrame = nil
            camera.stop()
        }
        .task {
            guard !yolo.isReady else { return }
            if let model = app.selectedModel {
                await yolo.load(from: model.url)
            } else if let bundled = ModelLoader.discoverModels().first(where: { $0.isBundled }) {
                await yolo.load(from: bundled.url)
            }
        }
    }

    // MARK: Aspect-fill mapping

    /// The rect the camera frame actually occupies inside the view when using
    /// videoGravity = .resizeAspectFill (the frame overflows the view).
    private func fillRect(viewSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0, frameAspect > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let viewAspect = viewSize.width / viewSize.height
        var w: CGFloat
        var h: CGFloat
        if frameAspect > viewAspect {
            // frame is wider -> match height, overflow horizontally
            h = viewSize.height
            w = h * frameAspect
        } else {
            // frame is taller -> match width, overflow vertically
            w = viewSize.width
            h = w / frameAspect
        }
        return CGRect(x: (viewSize.width - w) / 2,
                      y: (viewSize.height - h) / 2,
                      width: w,
                      height: h)
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: DS.Space.s) {
            StatPill(systemImage: "bolt.fill",
                     text: "\(Int(yolo.fps)) FPS",
                     tint: Palette.accent,
                     background: .white)
            // Capture rate, distinct from inference rate: if these two differ a
            // lot the bottleneck is the detector, not the camera.
            if camera.activeFrameRate > 0 {
                StatPill(systemImage: "camera.fill",
                         text: "\(Int(camera.activeFrameRate)) cap",
                         tint: Palette.inkSecondary,
                         background: .white)
            }
            StatPill(systemImage: "person.fill",
                     text: "\(yolo.detections.count) 人",
                     tint: Palette.success,
                     background: .white)
            Spacer(minLength: 0)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Palette.ink)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.white))
                    .shadow(color: Palette.shadowStrong, radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(DS.Motion.spring) { app.showCamera = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Palette.ink)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.white))
                    .shadow(color: Palette.shadowStrong, radius: 10, y: 3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.s)
    }

    private var bottomBar: some View {
        VStack(spacing: DS.Space.m) {
            if let err = yolo.errorMessage ?? camera.errorMessage {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(err)
                        .font(DS.Font.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(.white)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .fill(Palette.danger)
                )
                .padding(.horizontal, DS.Space.l)
            }

            HStack(spacing: DS.Space.s) {
                Circle()
                    .fill(yolo.isReady ? Palette.success : Palette.warning)
                    .frame(width: 7, height: 7)
                Text(yolo.status)
                    .font(DS.Font.caption)
                    .foregroundColor(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)

                if !yolo.isReady, let model = app.selectedModel {
                    Button {
                        Task { await yolo.reloadRecompiling(from: model.url) }
                    } label: {
                        Text("重新编译")
                            .font(DS.Font.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(Palette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.m)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .stroke(Palette.separator, lineWidth: 1)
            )
            .padding(.horizontal, DS.Space.l)

            // Live parameter readout so the effect of a change is obvious.
            HStack(spacing: DS.Space.s) {
                Text("阈值 \(String(format: "%.2f", settings.confidence))")
                Text("·")
                Text(settings.trackingEnabled ? "\(settings.requiredFrames) 帧确认" : "跟踪关")
                Text("·")
                Text(settings.personOnly ? "仅人" : "全类别")
                Text("·")
                Text("最小 \(String(format: "%.0f%%", settings.minSize * 100))")
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.35)))

            // Timing breakdown: inference vs. post-processing. This is how you
            // tell a slow model apart from slow decoding.
            if settings.showDebug {
                HStack(spacing: DS.Space.s) {
                    Text("推理 \(String(format: "%.0f", yolo.lastInferenceMs))ms")
                    Text("·")
                    Text("后处理 \(String(format: "%.1f", yolo.lastDecodeMs))ms")
                    Text("·")
                    Text("候选 \(yolo.rawCount)")
                    if settings.maxFPS > 0 {
                        Text("·")
                        Text("限 \(Int(settings.maxFPS))fps")
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.75))
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.30)))
            }
        }
        .padding(.bottom, DS.Space.xl)
    }
}

private struct StatPill: View {
    let systemImage: String
    let text: String
    let tint: Color
    let background: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(background))
        .shadow(color: Palette.shadowStrong, radius: 8, y: 2)
    }
}
