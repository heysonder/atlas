import Foundation

/// A portable JSON snapshot of everything SwiftData holds that can't be re-fetched
/// from Piped: watch history, search history, subscriptions, playlists, and taste
/// feedback. Used to carry data across a bundle-identifier change (which gives the
/// app a fresh, empty store). Downloads are intentionally excluded — those are
/// on-disk files, and the videos are re-downloadable.
struct AtlasBackup: Codable {
    var version = 2
    var exportedAt: Date
    var history: [HistoryDTO]
    var searches: [SearchDTO]
    var channels: [ChannelDTO]
    var playlists: [PlaylistDTO]
    var feedback: [FeedbackDTO]

    struct HistoryDTO: Codable {
        var videoID: String, title: String
        var uploader: String?, thumbnailURL: String?
        var watchedAt: Date, positionSeconds: Double, durationSeconds: Double
    }

    struct SearchDTO: Codable {
        var query: String
        var displayQuery: String?
        var lastSearchedAt: Date
        var count: Int
    }

    struct ChannelDTO: Codable {
        var channelID: String, name: String
        var avatarURL: String?, subscribedAt: Date
    }

    struct PlaylistDTO: Codable {
        var name: String, createdAt: Date, videos: [VideoDTO]

        struct VideoDTO: Codable {
            var videoID: String, title: String
            var uploader: String?, thumbnailURL: String?, duration: Int, addedAt: Date
        }
    }

    struct FeedbackDTO: Codable {
        var videoID: String, signal: Int, title: String
        var uploader: String?, category: String?, tags: [String]?, createdAt: Date
    }

    init(
        exportedAt: Date,
        history: [HistoryDTO],
        searches: [SearchDTO],
        channels: [ChannelDTO],
        playlists: [PlaylistDTO],
        feedback: [FeedbackDTO]
    ) {
        self.exportedAt = exportedAt
        self.history = history
        self.searches = searches
        self.channels = channels
        self.playlists = playlists
        self.feedback = feedback
    }

    enum CodingKeys: String, CodingKey {
        case version, exportedAt, history, searches, channels, playlists, feedback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        history = try container.decode([HistoryDTO].self, forKey: .history)
        searches = try container.decodeIfPresent([SearchDTO].self, forKey: .searches) ?? []
        channels = try container.decode([ChannelDTO].self, forKey: .channels)
        playlists = try container.decode([PlaylistDTO].self, forKey: .playlists)
        feedback = try container.decode([FeedbackDTO].self, forKey: .feedback)
    }
}

extension AtlasBackup.HistoryDTO {
    private enum DTOKeys: String, CodingKey {
        case videoID, title, uploader, thumbnailURL, watchedAt, positionSeconds, durationSeconds
    }

    /// v1 backups predate the resume-position fields (see `HistoryEntry`), so
    /// they decode with defaults instead of failing the whole import.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DTOKeys.self)
        self.init(
            videoID: try container.decode(String.self, forKey: .videoID),
            title: try container.decode(String.self, forKey: .title),
            uploader: try container.decodeIfPresent(String.self, forKey: .uploader),
            thumbnailURL: try container.decodeIfPresent(String.self, forKey: .thumbnailURL),
            watchedAt: try container.decode(Date.self, forKey: .watchedAt),
            positionSeconds: try container.decodeIfPresent(
                Double.self,
                forKey: .positionSeconds
            ) ?? 0,
            durationSeconds: try container.decodeIfPresent(
                Double.self,
                forKey: .durationSeconds
            ) ?? 0
        )
    }
}
