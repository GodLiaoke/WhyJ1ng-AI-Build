import SwiftUI
import Photos

// MARK: - Photo export + pre-detection tuning
//
// Two additions to the photo screen:
//   * adjustment parameters that apply to the image before it is run through
//     the model, so a dark or low-contrast shot can be made detectable without
//     leaving the app
//   * saving the annotated result into the photo library

struct PhotoExportControls: View {
    @Binding var brightness: Double
    @Binding var contrast: Double
    @Binding var saturation: Double
    let onReprocess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "识别前调节", systemImage: "slider.horizontal.2")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    Text("检测前先对图片做基础校正。夜间或逆光的照片调亮后，识别率会明显提升。")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    SliderRow(title: "亮度",
                              value: $brightness,
                              range: -0.5...0.5,
                              step: 0.05,
                              valueText: String(format: "%+.2f", brightness))

                    SliderRow(title: "对比度",
                              value: $contrast,
                              range: 0.5...1.5,
                              step: 0.05,
                              valueText: String(format: "%.2f", contrast))

                    SliderRow(title: "饱和度",
                              value: $saturation,
                              range: 0.0...2.0,
                              step: 0.05,
                              valueText: String(format: "%.2f", saturation))

                    HStack(spacing: DS.Space.s) {
                        Chip(text: "还原", selected: false, tint: Palette.inkSecondary) {
                            brightness = 0
                            contrast = 1
                            saturation = 1
                            onReprocess()
                        }
                        Chip(text: "夜间增强", selected: false, tint: Palette.accent) {
                            brightness = 0.25
                            contrast = 1.2
                            saturation = 1.1
                            onReprocess()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Image processing

enum PhotoAdjuster {

    /// Applies brightness / contrast / saturation through a Core Image filter
    /// chain and returns the adjusted image.
    static func apply(to image: UIImage,
                      brightness: Double,
                      contrast: Double,
                      saturation: Double) -> UIImage? {
        // Nothing to do at neutral values, which also keeps the fast path free
        // of a needless full-image render.
        guard brightness != 0 || contrast != 1 || saturation != 1,
              let input = image.ciImage ?? CIImage(image: image)
        else { return image }

        var ci = input
        if brightness != 0 {
            let f = CIFilter(name: "CIColorControls")
            f?.setValue(ci, forKey: kCIInputImageKey)
            f?.setValue(Float(brightness), forKey: kCIInputBrightnessKey)
            ci = f?.outputImage ?? ci
        }
        if contrast != 1 {
            let f = CIFilter(name: "CIColorControls")
            f?.setValue(ci, forKey: kCIInputImageKey)
            f?.setValue(Float(contrast), forKey: kCIInputContrastKey)
            ci = f?.outputImage ?? ci
        }
        if saturation != 1 {
            let f = CIFilter(name: "CIColorControls")
            f?.setValue(ci, forKey: kCIInputImageKey)
            f?.setValue(Float(saturation), forKey: kCIInputSaturationKey)
            ci = f?.outputImage ?? ci
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }
}

// MARK: - Photo library save

enum PhotoSaver {

    /// Saves an annotated image into the photo library.
    ///
    /// `NSPhotoLibraryAddUsageDescription` must be present in Info.plist; only
    /// *add* access is requested, which needs no prompt-blocking permission.
    static func save(_ image: UIImage) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }
}
