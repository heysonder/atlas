import Foundation

/// What the Feed tab shows. Persisted as a raw string via `@AppStorage("feedMode")`;
/// the player coordinator (plain UIKit) reads it through `FeedMode.current`.
enum FeedMode: String, CaseIterable, Identifiable {
    case subscriptions   // newest uploads from your subs (Piped /feed) — default
    case forYouRelated   // For You: basic Piped "related"
    case forYouCustom    // For You: our on-device topic match (personalized)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subscriptions: "Subscriptions"
        case .forYouRelated: "For You — Related"
        case .forYouCustom: "For You — Personalized"
        }
    }

    var blurb: String {
        switch self {
        case .subscriptions: "Newest uploads from channels you subscribe to."
        case .forYouRelated: "Videos Piped relates to your recent watches."
        case .forYouCustom: "On-device topic match that learns from Suggest more / less."
        }
    }

    /// True for the custom recommender, whose thumbs-up/down feedback is shown.
    var isPersonalized: Bool { self == .forYouCustom }
    var isForYou: Bool { self != .subscriptions }

    /// The `@AppStorage`/UserDefaults key the feed mode is persisted under.
    /// (FeedView still spells the literal out; keep them in sync.)
    static let storageKey = "feedMode"

    /// The persisted setting, for non-SwiftUI call sites (e.g. the player coordinator).
    static var current: FeedMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(FeedMode.init) ?? .subscriptions
    }
}
