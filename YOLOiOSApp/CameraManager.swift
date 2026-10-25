import AVFoundation
import UIKit
import SwiftUI

// MARK: - Camera manager
// AVCaptureSession -> portrait CVPixelBuffer frames
final class CameraManager: NSObject, ObservableObject {

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private var isConfigured = false

    @Published var isRunning = false
    @Published var permissionGranted = false
    @Published var errorMessage: String? = nil
    /// Frame rate the capture device is actually delivering, if it could be set.
    @Published var activeFrameRate: Double = 0

    /// Called on the video queue for every frame (not the main thread).
    var onFrame: ((CVPixelBuffer) -> Void)?

    override init() {
        super.init()
        checkPermission()
    }

    private func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.permissionGranted = true }
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async { self?.permissionGranted = ok }
                if ok { self?.configureSession() }
            }
        default:
            DispatchQueue.main.async {
                self.errorMessage = "摄像头权限被拒绝，请在系统设置中开启"
            }
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else { return }

            self.session.beginConfiguration()
            // 1280x720 is the sweet spot: enough detail for 640-input YOLO while
            // cutting the per-frame pixel copy that feeds Vision roughly in half
            // versus 1080p.
            if self.session.canSetSessionPreset(.hd1280x720) {
                self.session.sessionPreset = .hd1280x720
            }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video,
                                                       position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.errorMessage = "无法访问后置摄像头" }
                return
            }

            if self.session.canAddInput(input) { self.session.addInput(input) }

            // Frame rate must be configured explicitly. Without this the session
            // sits at the format's minimum, which on this hardware is ~16fps —
            // far below what the device and the detector can sustain.
            self.configureFrameRate(device: device)

            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.frame"))

            if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }

            // Rotate buffers upright so Vision receives a portrait image and
            // detected boxes line up with the portrait preview layer.
            if let conn = self.videoOutput.connection(with: .video) {
                if #available(iOS 17.0, *), conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                } else {
                    conn.videoOrientation = .portrait
                }
            }

            self.isConfigured = true
            self.session.commitConfiguration()
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.isRunning = true }
        }
    }

    /// Picks the highest frame rate the active format supports, up to a cap.
    ///
    /// The cap exists because the detector cannot consume 120fps: frames beyond
    /// the inference rate are dropped anyway, and requesting them costs power and
    /// heat for nothing. `activeVideoMinFrameDuration` / `MaxFrameDuration` are
    /// the only settings that actually change what the camera delivers.
    private func configureFrameRate(device: AVCaptureDevice, cap: Double = 60) {
        // `activeFormat` is the highest-quality format the preset allows, which
        // is where the frame-rate ranges live.
        let format = device.activeFormat
        let ranges = format.videoSupportedFrameRateRanges
        guard let best = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return }

        let target = min(best.maxFrameRate, cap)
        guard target > 0 else { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // Guard against a format that reports a range it will not honour:
            // setting a duration below the supported minimum throws.
            let duration = CMTime(value: 1, timescale: CMTimeScale(target.rounded()))
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= target && target <= $0.maxFrameRate
            }) {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                DispatchQueue.main.async {
                    self.activeFrameRate = target
                }
            }
        } catch {
            // Leave the format at its default rather than failing the session.
            DispatchQueue.main.async {
                self.errorMessage = "无法设置帧率：\(error.localizedDescription)"
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb)
    }
}

// MARK: - Preview layer wrapper

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        if let conn = v.previewLayer.connection {
            if #available(iOS 17.0, *), conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            } else {
                conn.videoOrientation = .portrait
            }
        }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
