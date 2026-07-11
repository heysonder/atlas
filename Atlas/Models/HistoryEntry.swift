import Foundation
import SwiftData

/// A locally recorded watch-history entry.
@Model
final class HistoryEntry {
    @Attribute(.unique) var videoID: String
    var title: String
    var uploader: String?
    var thumbnailURL: String?
    var watchedAt: Date
    /// Last playback position (seconds) for resume. Inline default lets SwiftData
    /// migrate existing rows that predate this field.
    var positionSeconds: Double = 0
    /// Total video length (seconds), when known.
    var durationSeconds: Double = 0

    init(
        videoID: String, title: String, uploader: String? = nil,
        thumbnailURL: String? = nil, watchedAt: Date = .now,
        positionSeconds: Double = 0, durationSeconds: Double = 0
    ) {
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
        self.thumbnailURL = thumbnailURL
        self.watchedAt = watchedAt
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
    }

    /// Whether this counts as "watched" for the badge: at least 80% seen. End
    /// cards, outros and ads mean people stop in the last 10–20%, so near the end
    /// already counts as finished — matching where `RecommendationEngine.watchWeight`
    /// tops out. Unknown-length videos don't qualify; we can't confirm how much was
    /// seen. (Distinct from mere history membership, which drives resume.)
    var isWatched: Bool {
        guard durationSeconds > 0 else { return false }
        return positionSeconds / durationSeconds >= 0.8
    }
}

/// Memoizes the watched-ID set derived from the full history table. Playback
/// bumps `positionSeconds`/`watchedAt` periodically, invalidating any history
/// `@Query` — so views hold one of these in `@State` and read through it instead
/// of re-filtering the whole table on every body evaluation. The set is rebuilt
/// only when the row count changes or a row crosses the watched threshold.
@MainActor
final class WatchedIDsMemo {
    private static var membershipRevision = 0

    private var key: Key?
    private var cached: Set<String> = []
    private(set) var rebuildCount = 0

    private struct Key: Equatable {
        var count: Int
        var membershipRevision: Int
    }

    func ids(for history: [HistoryEntry]) -> Set<String> {
        let key = Key(count: history.count, membershipRevision: Self.membershipRevision)
        if key != self.key {
            self.key = key
            cached = Set(history.filter(\.isWatched).map(\.videoID))
            rebuildCount += 1
        }
        return cached
    }

    static func noteMembershipChange() {
        membershipRevision &+= 1
    }
}
