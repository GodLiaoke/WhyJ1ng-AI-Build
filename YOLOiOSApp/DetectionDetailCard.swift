import SwiftUI

// MARK: - Detection detail card
//
// Opened by tapping a detection box on the camera screen. Shows everything the
// pipeline actually knows about that one result, which doubles as a way to
// sanity-check the decode maths (normalised vs. pixel coordinates).

struct DetectionDetailCard: View {
    let detection: Detection
    /// Width/height of the source camera frame.
    let frameAspect: CGFloat
    let onClose: () -> Void

    private var frameSize: CGSize {
        // Reconstruct a plausible source resolution from the aspect ratio so the
        // pixel numbers are meaningful. Camera preset is 1280x720 rotated to
        // portrait, i.e. 720x1280.
        if abs(frameAspect - (720.0 / 1280.0)) < 0.02 { return CGSize(width: 720, height: 1280) }
        if frameAspect >= 1 {
            return CGSize(width: 1280, height: 1280 / max(frameAspect, 0.01))
        }
        return CGSize(width: 1280 * frameAspect, height: 1280)
    }

    private var pixelRect: CGRect {
        let s = frameSize
        return CGRect(x: detection.rect.minX * s.width,
                      y: detection.rect.minY * s.height,
                      width: detection.rect.width * s.width,
                      height: detection.rect.height * s.height)
    }

    private var confidenceColor: Color {
        if detection.confidence >= 0.75 { return Palette.success }
        if detection.confidence >= 0.5 { return Palette.accent }
        return Palette.warning
    }

    private var areaPercent: Double {
        Double(detection.rect.width * detection.rect.height) * 100
    }

    private var aspectText: String {
        let w = detection.rect.width, h = detection.rect.height
        guard h > 0 else { return "—" }
        return String(format: "%.2f : 1", w / h)
    }

    var body: some View {
        SurfaceCard(padding: DS.Space.l, elevated: true) {
            VStack(alignment: .leading, spacing: DS.Space.m) {

                // Header
                HStack(spacing: DS.Space.s) {
                    ZStack {
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(confidenceColor.opacity(0.14))
                            .frame(width: 32, height: 32)
                        Image(systemName: detection.label == "person"
                              ? "person.fill" : "cube.transparent.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(confidenceColor)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(detection.label)
                            .font(DS.Font.headline)
                            .foregroundColor(Palette.ink)
                        Text("类别 · COCO \(Self.cocoIndex(detection.label))")
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.inkTertiary)
                    }

                    Spacer(minLength: 0)

                    Text("\(Int(detection.confidence * 100))%")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(confidenceColor)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Palette.inkSecondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Palette.surfaceAlt))
                    }
                    .buttonStyle(.plain)
                }

                // Confidence bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.surfaceAlt)
                        Capsule()
                            .fill(confidenceColor)
                            .frame(width: max(geo.size.width * CGFloat(detection.confidence), 3))
                    }
                }
                .frame(height: 5)

                Hairline()

                // Geometry
                VStack(spacing: DS.Space.s) {
                    InfoRow(label: "归一化框",
                            value: String(format: "%.3f, %.3f  %.3f × %.3f",
                                          detection.rect.minX, detection.rect.minY,
                                          detection.rect.width, detection.rect.height),
                            mono: true)
                    InfoRow(label: "像素框（约）",
                            value: String(format: "%.0f, %.0f  %.0f × %.0f",
                                          pixelRect.minX, pixelRect.minY,
                                          pixelRect.width, pixelRect.height),
                            mono: true)
                    InfoRow(label: "画面占比",
                            value: String(format: "%.1f%%", areaPercent),
                            mono: true)
                    InfoRow(label: "宽高比", value: aspectText, mono: true)
                    InfoRow(label: "追踪帧数", value: "\(detection.hits)", mono: true)
                    InfoRow(label: "源帧尺寸",
                            value: String(format: "%.0f × %.0f", frameSize.width, frameSize.height),
                            mono: true)
                }

                if detection.confidence < 0.5 {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("置信度偏低，可能是误报")
                            .font(DS.Font.caption)
                    }
                    .foregroundColor(Palette.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(Palette.warningSoft)
                    )
                }
            }
        }
    }

    /// COCO class id for the few labels this app can produce.
    static func cocoIndex(_ label: String) -> Int {
        if label.hasPrefix("obj ") {
            return Int(label.dropFirst(4)) ?? -1
        }
        return YOLOViewModel.cocoNames.firstIndex(of: label) ?? -1
    }
}
