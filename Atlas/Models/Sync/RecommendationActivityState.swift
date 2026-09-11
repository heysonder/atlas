import Foundation
import SwiftData

/// A one-time import of a device's old aggregate. Old training outcomes do not
/// count again; only newly recorded events contribute alongside this baseline.
/// A zero-count row is a tap reset retained for 45 days independently of its
/// training outcome, so expiring an old tapped outcome cannot revive penalties.
@Model
final class FeedImpressionBaseline {
    @Attribute(.unique) var id: UUID
    var videoID: String
    var count: Int
    var lastShownAt: Date

    init(id: UUID = UUID(), videoID: String, count: Int, lastShownAt: Date) {
        self.id = id
        self.videoID = videoID
        self.count = count
        self.lastShownAt = lastShownAt
    }
}

/// Local migration identity and the shared monotone activity retention barrier.
/// Only the cutoff is transported; installation identity/migration are local.
@Model
final class RecommendationActivityState {
    @Attribute(.unique) var id: String
    var originID: String
    var migrated: Bool
    var retentionCutoff: Date
    var retentionEventID: String

    init() {
        id = "default"
        originID = UUID().uuidString.lowercased()
        migrated = false
        retentionCutoff = Date(timeIntervalSince1970: 0)
        retentionEventID = ""
    }
}
