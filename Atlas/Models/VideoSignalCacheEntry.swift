import Foundation
import SwiftData
import PipedKit

/// Cached enrichment from `/streams` used by For You ranking. This avoids
/// re-resolving the same shortlist just to recover category/tags on refresh.
@Model
final class VideoSignalCacheEntry {
    @Attribute(.unique) var videoID: String
    var title: String?
    var uploader: String?
    var channelID: String?
    var category: String?
    var tags: [String]?
    var topicKey: String?
    var updatedAt: Date

    init(videoID: String, title: String? = nil, uploader: String? = nil,
         channelID: String? = nil, category: String? = nil, tags: [String]? = nil,
         topicKey: String? = nil, updatedAt: Date = .now) {
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
        self.channelID = channelID
        self.category = category
        self.tags = tags
        self.topicKey = topicKey
        self.updatedAt = updatedAt
    }

    var videoSignals: VideoSignals {
        VideoSignals(category: category, tags: tags ?? [], topicKey: topicKey)
    }

    func update(from detail: VideoDetail, fallback item: StreamItem?,
                topicKey: String?, at date: Date = .now) {
        title = detail.title ?? item?.displayTitle
        uploader = detail.uploader ?? item?.uploaderName
        channelID = detail.channelID ?? item?.uploaderChannelID
        category = detail.category
        tags = detail.tags ?? []
        self.topicKey = topicKey
        updatedAt = date
    }
}
