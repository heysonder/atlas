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

    init(videoID: String, title: String, uploader: String? = nil,
         thumbnailURL: String? = nil, watchedAt: Date = .now,
         positionSeconds: Double = 0, durationSeconds: Double = 0) {
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
        self.thumbnailURL = thumbnailURL
        self.watchedAt = watchedAt
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
    }
}
