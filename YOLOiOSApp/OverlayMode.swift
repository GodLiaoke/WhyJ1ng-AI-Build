import Foundation
import UIKit

// MARK: - Overlay presentation mode
//
// Superseded by `LaunchMode`, which is chosen at overlay startup and also
// governs whether the kernel layer is touched. Kept as a thin alias so the
// window-level mapping lives in one place.

typealias OverlayMode = LaunchMode

extension LaunchMode {
    /// Window level used for this mode.
    ///
    /// The system-wide level is deliberately `alert + 1` rather than an
    /// arbitrarily huge number. A window level that far above the system's own
    /// windows still renders, but the touch-delivery path stops routing events
    /// to it — the panel becomes visible and completely inert. Staying just
    /// above the alert level keeps the window interactive while still floating
    /// over ordinary app content.
    var windowLevelOverride: UIWindow.Level {
        switch self {
        case .trollstore:
            return .alert + 1
        case .selfSigned:
            // Above this app's content, below system alerts.
            return .normal + 1
        }
    }
}
