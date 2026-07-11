import Foundation
import PipedKit
import SwiftData

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

    init(
        videoID: String, title: String? = nil, uploader: String? = nil,
        channelID: String? = nil, category: String? = nil, tags: [String]? = nil,
        topicKey: String? = nil, updatedAt: Date = .now
    ) {
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

    @discardableResult
    func update(
        from detail: VideoDetail, fallback item: StreamItem?,
        topicKey: String?, at date: Date = .now
    ) -> Bool {
        let resolvedTitle = detail.title ?? item?.displayTitle
        let resolvedUploader = detail.uploader ?? item?.uploaderName
        let resolvedChannelID = detail.channelID ?? item?.uploaderChannelID
        let resolvedTags = detail.tags ?? []
        do {
            try PersistedMetadataPolicy.requireIdentifier(videoID, field: "signalCache.videoID")
            try PersistedMetadataPolicy.requireOptionalText(
                resolvedTitle, field: "signalCache.title")
            try PersistedMetadataPolicy.requireOptionalText(
                resolvedUploader, field: "signalCache.uploader")
            if let resolvedChannelID {
                try PersistedMetadataPolicy.requireIdentifier(
                    resolvedChannelID, field: "signalCache.channelID")
            }
            try PersistedMetadataPolicy.requireOptionalText(
                detail.category, field: "signalCache.category")
            try PersistedMetadataPolicy.requireTags(
                resolvedTags, field: "signalCache.tags")
            try PersistedMetadataPolicy.requireOptionalText(
                topicKey, field: "signalCache.topicKey")
            try PersistedMetadataPolicy.requireFiniteDate(date, field: "signalCache.updatedAt")
        } catch {
            return false
        }
        title = resolvedTitle
        uploader = resolvedUploader
        channelID = resolvedChannelID
        category = detail.category
        tags = resolvedTags
        self.topicKey = topicKey
        updatedAt = date
        return true
    }
}
