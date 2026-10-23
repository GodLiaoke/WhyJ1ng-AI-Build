import Foundation
import Combine

// MARK: - Detector settings
// Shared, live-editable detection parameters. YOLOViewModel reads these on
// every frame, so changes take effect immediately without reloading the model.

final class DetectorSettings: ObservableObject {
    static let shared = DetectorSettings()

    private enum Key {
        static let confidence = "det.confidence"
        static let personOnly = "det.personOnly"
        static let minSize = "det.minSize"
        static let requiredFrames = "det.requiredFrames"
        static let nmsIoU = "det.nmsIoU"
        static let tracking = "det.tracking"
        static let maxFPS = "det.maxFPS"
        static let showDebug = "det.showDebug"
        static let boxTapDetails = "det.boxTapDetails"
        static let overlayTapThrough = "det.overlayTapThrough"
    }

    /// Minimum confidence for the `person` class.
    @Published var confidence: Double {
        didSet { UserDefaults.standard.set(confidence, forKey: Key.confidence) }
    }

    /// Keep only the person class (COCO id 0). Off = draw every class.
    @Published var personOnly: Bool {
        didSet { UserDefaults.standard.set(personOnly, forKey: Key.personOnly) }
    }

    /// Ignore boxes smaller than this fraction of the frame's shorter side.
    @Published var minSize: Double {
        didSet { UserDefaults.standard.set(minSize, forKey: Key.minSize) }
    }

    /// How many consecutive frames a box must appear in before it is drawn.
    /// This is the main defence against flickering false positives.
    @Published var requiredFrames: Int {
        didSet { UserDefaults.standard.set(requiredFrames, forKey: Key.requiredFrames) }
    }

    /// NMS IoU threshold.
    @Published var nmsIoU: Double {
        didSet { UserDefaults.standard.set(nmsIoU, forKey: Key.nmsIoU) }
    }

    /// Enable temporal tracking + persistence filtering.
    @Published var trackingEnabled: Bool {
        didSet { UserDefaults.standard.set(trackingEnabled, forKey: Key.tracking) }
    }

    /// Upper bound on inference rate. 0 = uncapped (run every frame).
    /// Capping frees thermal headroom, which actually *raises* sustained fps.
    @Published var maxFPS: Double {
        didSet { UserDefaults.standard.set(maxFPS, forKey: Key.maxFPS) }
    }

    /// Show inference/decode timings on the detection screen.
    @Published var showDebug: Bool {
        didSet { UserDefaults.standard.set(showDebug, forKey: Key.showDebug) }
    }

    /// Tapping a detection box shows its details. Off = boxes are decorative.
    @Published var boxTapDetails: Bool {
        didSet { UserDefaults.standard.set(boxTapDetails, forKey: Key.boxTapDetails) }
    }

    /// In the overlay scanner, tapping a detected target sends a synthetic tap
    /// to the app underneath at that point ("click the thing YOLO found").
    @Published var overlayTapThrough: Bool {
        didSet { UserDefaults.standard.set(overlayTapThrough, forKey: Key.overlayTapThrough) }
    }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Key.confidence: 0.45,
            Key.personOnly: true,
            Key.minSize: 0.04,
            Key.requiredFrames: 3,
            Key.nmsIoU: 0.45,
            Key.tracking: true,
            Key.maxFPS: 0.0,
            Key.showDebug: true,
            Key.boxTapDetails: true,
            Key.overlayTapThrough: false,
        ])
        confidence = d.double(forKey: Key.confidence)
        personOnly = d.bool(forKey: Key.personOnly)
        minSize = d.double(forKey: Key.minSize)
        requiredFrames = d.integer(forKey: Key.requiredFrames)
        nmsIoU = d.double(forKey: Key.nmsIoU)
        trackingEnabled = d.bool(forKey: Key.tracking)
        maxFPS = d.double(forKey: Key.maxFPS)
        showDebug = d.bool(forKey: Key.showDebug)
        boxTapDetails = d.bool(forKey: Key.boxTapDetails)
        overlayTapThrough = d.bool(forKey: Key.overlayTapThrough)
    }

    func resetToDefaults() {
        confidence = 0.45
        personOnly = true
        minSize = 0.04
        requiredFrames = 3
        nmsIoU = 0.45
        trackingEnabled = true
        maxFPS = 0.0
        showDebug = true
        boxTapDetails = true
        overlayTapThrough = false
    }
}
