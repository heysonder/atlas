import UIKit

/// Temporarily narrows the orientations the app accepts. The embedded player
/// uses it when leaving full screen while the phone is still held sideways:
/// without a lock, the system rotates the interface back to landscape the
/// moment the portrait request completes, leaving the inline layout inside
/// a landscape window.
@MainActor
final class InterfaceOrientationLock {
    static let shared = InterfaceOrientationLock()

    /// `nil` means "whatever Info.plist allows".
    private(set) var mask: UIInterfaceOrientationMask?

    private init() {}

    /// Matches `UISupportedInterfaceOrientations` in project.yml.
    var defaultMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    var effectiveMask: UIInterfaceOrientationMask { mask ?? defaultMask }

    /// Restricts to `orientations` and rotates the interface to match.
    func lock(_ orientations: UIInterfaceOrientationMask) {
        mask = orientations
        apply(rotatingTo: orientations)
    }

    /// Restores the Info.plist set; the interface follows the device again.
    /// Pass `rotatingTo` to also request a specific orientation right away.
    func unlock(rotatingTo orientations: UIInterfaceOrientationMask? = nil) {
        mask = nil
        apply(rotatingTo: orientations)
    }

    private func apply(rotatingTo orientations: UIInterfaceOrientationMask?) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        where scene.activationState == .foregroundActive {
            if let orientations {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
            }
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}
