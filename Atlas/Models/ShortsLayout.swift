import Foundation

/// How visible Shorts are arranged in the Home feed. Persisted as a raw string
/// in `UserDefaults` via `AppModel.shortsLayout`. Only applies when Shorts are
/// shown (i.e. "Hide Shorts" is off); search and channels always use `.inline`.
enum ShortsLayout: String, CaseIterable, Identifiable, Sendable {
    case inline  // paired two-per-row, mixed into the feed (default)
    case carousel  // collected into one horizontal shelf near the top

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inline: "In feed"
        case .carousel: "Carousel"
        }
    }

    var blurb: String {
        switch self {
        case .inline: "Shorts appear two-per-row, mixed into your feed."
        case .carousel: "Shorts are collected into one swipeable row near the top of your feed."
        }
    }
}
