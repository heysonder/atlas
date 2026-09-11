import Foundation
import SwiftData

/// Frozen persistence contract from the last schema before explicit iCloud sync.
/// Keep these stored properties, defaults and relationships unchanged. The app
/// originally opened this shape through `Schema(modelTypes)`, whose version is
/// 1.0.0. Historical types deliberately keep the same unqualified entity names.
enum AtlasSchemaV1: VersionedSchema {
    nonisolated static let versionIdentifier = Schema.Version(1, 0, 0)

    nonisolated static var models: [any PersistentModel.Type] {
        [
            SubscribedChannel.self,
            HistoryEntry.self,
            Playlist.self,
            PlaylistVideo.self,
            DownloadedVideo.self,
            Feedback.self,
            SearchEntry.self,
            VideoSignalCacheEntry.self,
            RecommendationProfileSnapshot.self,
            FeedImpressionEntry.self,
            RecommendationOutcomeEntry.self,
        ]
    }

    @Model
    final class SubscribedChannel {
        @Attribute(.unique) var channelID: String
        var name: String
        var avatarURL: String?
        var subscribedAt: Date

        init(channelID: String, name: String, avatarURL: String? = nil, subscribedAt: Date = .now) {
            self.channelID = channelID
            self.name = name
            self.avatarURL = avatarURL
            self.subscribedAt = subscribedAt
        }
    }

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
    }

    @Model
    final class Playlist {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        @Relationship(deleteRule: .cascade, inverse: \PlaylistVideo.playlist)
        var videos: [PlaylistVideo]

        init(id: UUID = UUID(), name: String, createdAt: Date = .now, videos: [PlaylistVideo] = []) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.videos = videos
        }
    }

    @Model
    final class PlaylistVideo {
        var videoID: String
        var title: String
        var uploader: String?
        var thumbnailURL: String?
        var duration: Int
        var addedAt: Date
        var playlist: Playlist?

        init(
            videoID: String, title: String, uploader: String? = nil,
            thumbnailURL: String? = nil, duration: Int = 0, addedAt: Date = .now
        ) {
            self.videoID = videoID
            self.title = title
            self.uploader = uploader
            self.thumbnailURL = thumbnailURL
            self.duration = duration
            self.addedAt = addedAt
        }
    }

    @Model
    final class DownloadedVideo {
        @Attribute(.unique) var videoID: String
        var title: String
        var uploader: String?
        /// Relative file name of the downloaded `.mp4`, e.g. "VIDEOID.mp4".
        var fileName: String
        /// Relative file name of the locally cached poster, so it shows offline.
        var thumbnailFileName: String?
        /// Relative file name of the selected caption track, when the source had one.
        var captionFileName: String?
        var captionMimeType: String?
        var captionLanguageCode: String?
        var captionName: String?
        var durationSeconds: Int
        /// Human label like "1080p", when the source resolution is known.
        var qualityLabel: String?
        /// On-disk size of the media file, for display.
        var byteCount: Int64
        var createdAt: Date

        init(
            videoID: String,
            title: String,
            uploader: String? = nil,
            fileName: String,
            thumbnailFileName: String? = nil,
            captionFileName: String? = nil,
            captionMimeType: String? = nil,
            captionLanguageCode: String? = nil,
            captionName: String? = nil,
            durationSeconds: Int = 0,
            qualityLabel: String? = nil,
            byteCount: Int64 = 0,
            createdAt: Date = .now
        ) {
            self.videoID = videoID
            self.title = title
            self.uploader = uploader
            self.fileName = fileName
            self.thumbnailFileName = thumbnailFileName
            self.captionFileName = captionFileName
            self.captionMimeType = captionMimeType
            self.captionLanguageCode = captionLanguageCode
            self.captionName = captionName
            self.durationSeconds = durationSeconds
            self.qualityLabel = qualityLabel
            self.byteCount = byteCount
            self.createdAt = createdAt
        }
    }

    @Model
    final class Feedback {
        @Attribute(.unique) var videoID: String
        /// +1 = suggest more, −1 = suggest less.
        var signal: Int
        var title: String
        var uploader: String?
        var category: String?
        var tags: [String]?
        var createdAt: Date

        init(
            videoID: String, signal: Int, title: String, uploader: String? = nil,
            category: String? = nil, tags: [String]? = nil, createdAt: Date = .now
        ) {
            self.videoID = videoID
            self.signal = signal
            self.title = title
            self.uploader = uploader
            self.category = category
            self.tags = tags
            self.createdAt = createdAt
        }
    }

    @Model
    final class SearchEntry {
        @Attribute(.unique) var query: String
        var displayQuery: String?
        var lastSearchedAt: Date
        var count: Int

        init(query: String, displayQuery: String? = nil, lastSearchedAt: Date = .now, count: Int = 1) {
            self.query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.displayQuery = (displayQuery ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
            self.lastSearchedAt = lastSearchedAt
            self.count = min(max(1, count), 1_000_000)
        }
    }

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
    }

    @Model
    final class RecommendationProfileSnapshot {
        @Attribute(.unique) var id: String
        var signature: String
        var relatedSeedIDs: [String]
        var explorationSeedIDs: [String]
        var candidateSearchQueries: [String]
        var savedSeedIDs: [String]
        var channelAffinityKeys: [String]
        var channelAffinityValues: [Double]
        var updatedAt: Date

        init(
            id: String = "default", signature: String,
            relatedSeedIDs: [String], explorationSeedIDs: [String],
            candidateSearchQueries: [String], savedSeedIDs: [String],
            channelAffinityKeys: [String], channelAffinityValues: [Double],
            updatedAt: Date = .now
        ) {
            self.id = id
            self.signature = signature
            self.relatedSeedIDs = relatedSeedIDs
            self.explorationSeedIDs = explorationSeedIDs
            self.candidateSearchQueries = candidateSearchQueries
            self.savedSeedIDs = savedSeedIDs
            self.channelAffinityKeys = channelAffinityKeys
            self.channelAffinityValues = channelAffinityValues
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class FeedImpressionEntry {
        @Attribute(.unique) var videoID: String
        var count: Int
        var lastShownAt: Date

        init(videoID: String, count: Int = 1, lastShownAt: Date = .now) {
            self.videoID = videoID
            self.count = count
            self.lastShownAt = lastShownAt
        }
    }

    @Model
    final class RecommendationOutcomeEntry {
        var videoID: String
        var shownAt: Date
        /// 0-based rank position on the first screen — needed to correct for
        /// position bias when fitting (top slots get taps just for being on top).
        var position: Int
        var tapped: Bool
        var tappedAt: Date?

        var topicSimilarity: Double
        var longTermSimilarity: Double
        var categoryFit: Double
        var corroboration: Int
        var freshness: Double
        var channelAffinity: Double
        var isSubscribed: Bool
        var dislikeSimilarity: Double
        var priorImpressions: Int
        var fromRelated: Bool
        var fromSearch: Bool
        var fromSaved: Bool
        var fromSubscription: Bool
        var fromExploration: Bool
        var usedContextualEmbedding: Bool

        init(videoID: String, shownAt: Date, position: Int) {
            self.videoID = videoID
            self.shownAt = shownAt
            self.position = position
            self.tapped = false
            self.tappedAt = nil
            self.topicSimilarity = 0
            self.longTermSimilarity = 0
            self.categoryFit = 0
            self.corroboration = 0
            self.freshness = 0
            self.channelAffinity = 0
            self.isSubscribed = false
            self.dislikeSimilarity = 0
            self.priorImpressions = 0
            self.fromRelated = false
            self.fromSearch = false
            self.fromSaved = false
            self.fromSubscription = false
            self.fromExploration = false
            self.usedContextualEmbedding = false
        }
    }
}

/// Current local library and sync journal. Automatic CloudKit mirroring remains
/// disabled; the explicit sync coordinator owns all network synchronization.
enum AtlasSchemaV2: VersionedSchema {
    nonisolated static let versionIdentifier = Schema.Version(2, 0, 0)

    nonisolated static var models: [any PersistentModel.Type] {
        AtlasModelSchema.modelTypes
    }
}

enum AtlasSchemaMigrationPlan: SchemaMigrationPlan {
    nonisolated static var schemas: [any VersionedSchema.Type] {
        [AtlasSchemaV1.self, AtlasSchemaV2.self]
    }

    nonisolated static var stages: [MigrationStage] {
        [.lightweight(fromVersion: AtlasSchemaV1.self, toVersion: AtlasSchemaV2.self)]
    }
}
