import SwiftUI
import UIKit

/// Holds the orientations the app currently permits. Outside the player the app
/// uses its "base" set — portrait-only on iPhone, all orientations on iPad — and
/// the player additionally allows landscape. On Mac (Catalyst) windows aren't
/// orientation-locked, so the runtime calls below compile out.
@MainActor
final class OrientationGate {
    static let shared = OrientationGate()

    /// Orientations allowed when the video player isn't on screen.
    var base: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    lazy var mask: UIInterfaceOrientationMask = base
}

/// Bridges the orientation gate to UIKit, which asks the delegate which
/// orientations each window supports.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?)
    -> UIInterfaceOrientationMask {
        OrientationGate.shared.mask
    }
}

enum Orientation {
    /// Allow landscape in addition to the base set (used while the player is visible).
    static func allowVideo() {
        OrientationGate.shared.mask = [.portrait, .landscapeLeft, .landscapeRight]
        apply(snapToPortrait: false)
    }

    /// Restore the base orientations (portrait on iPhone, all on iPad) and rotate
    /// back to portrait if that's the only thing now allowed.
    static func lockPortrait() {
        let base = OrientationGate.shared.base
        OrientationGate.shared.mask = base
        apply(snapToPortrait: base == .portrait)
    }

    private static func apply(snapToPortrait: Bool) {
        #if !targetEnvironment(macCatalyst)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        if snapToPortrait {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        #endif
    }
}
