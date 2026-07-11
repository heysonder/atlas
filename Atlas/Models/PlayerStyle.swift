import Foundation

/// Which player UI opens when you tap a video. The native full-screen player is
/// the default; the embedded option plays inline with the info panel beneath it.
enum PlayerStyle: String, CaseIterable, Identifiable {
    case fullscreen
    case embedded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullscreen: "Fullscreen"
        case .embedded: "Embedded"
        }
    }

    var blurb: String {
        switch self {
        case .fullscreen:
            "Tapping a video opens the native full-screen player; tap ⓘ for details."
        case .embedded:
            "Tapping a video opens an inline player with the channel, description, and comments scrolling beneath it."
        }
    }
}
