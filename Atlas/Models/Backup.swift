import Foundation
import SwiftData

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

    init(exportedAt: Date, history: [HistoryDTO], searches: [SearchDTO],
         channels: [ChannelDTO], playlists: [PlaylistDTO], feedback: [FeedbackDTO]) {
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

enum BackupStore {
    /// Write a JSON backup to a temp file and return its URL (for the share sheet).
    static func export(from context: ModelContext) throws -> URL {
        let history = try context.fetch(FetchDescriptor<HistoryEntry>())
        let searches = try context.fetch(FetchDescriptor<SearchEntry>())
        let channels = try context.fetch(FetchDescriptor<SubscribedChannel>())
        let playlists = try context.fetch(FetchDescriptor<Playlist>())
        let feedback = try context.fetch(FetchDescriptor<Feedback>())

        let backup = AtlasBackup(
            exportedAt: .now,
            history: history.map {
                .init(videoID: $0.videoID, title: $0.title, uploader: $0.uploader,
                      thumbnailURL: $0.thumbnailURL, watchedAt: $0.watchedAt,
                      positionSeconds: $0.positionSeconds, durationSeconds: $0.durationSeconds)
            },
            searches: searches.map {
                .init(query: $0.query, displayQuery: $0.displayQuery,
                      lastSearchedAt: $0.lastSearchedAt, count: $0.count)
            },
            channels: channels.map {
                .init(channelID: $0.channelID, name: $0.name,
                      avatarURL: $0.avatarURL, subscribedAt: $0.subscribedAt)
            },
            playlists: playlists.map { p in
                .init(name: p.name, createdAt: p.createdAt, videos: p.orderedVideos.map {
                    .init(videoID: $0.videoID, title: $0.title, uploader: $0.uploader,
                          thumbnailURL: $0.thumbnailURL, duration: $0.duration, addedAt: $0.addedAt)
                })
            },
            feedback: feedback.map {
                .init(videoID: $0.videoID, signal: $0.signal, title: $0.title,
                      uploader: $0.uploader, category: $0.category, tags: $0.tags, createdAt: $0.createdAt)
            })

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(backup)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-backup.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    struct Summary {
        var history = 0, searches = 0, channels = 0, playlists = 0, feedback = 0
        var text: String {
            "Imported \(history) history, \(searches) searches, \(channels) channels, "
                + "\(playlists) playlists, \(feedback) ratings."
        }
    }

    /// Merge a backup into the current store. Existing rows (matched by their unique
    /// key) are kept as-is, so re-importing is safe and never duplicates.
    @discardableResult
    static func restore(from url: URL, into context: ModelContext) throws -> Summary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(AtlasBackup.self, from: Data(contentsOf: url))
        var summary = Summary()

        let haveHistory = Set((try? context.fetch(FetchDescriptor<HistoryEntry>()))?.map(\.videoID) ?? [])
        for h in backup.history where !haveHistory.contains(h.videoID) {
            context.insert(HistoryEntry(videoID: h.videoID, title: h.title, uploader: h.uploader,
                                        thumbnailURL: h.thumbnailURL, watchedAt: h.watchedAt,
                                        positionSeconds: h.positionSeconds, durationSeconds: h.durationSeconds))
            summary.history += 1
        }

        var haveSearches = Set((try? context.fetch(FetchDescriptor<SearchEntry>()))?.map(\.query) ?? [])
        for s in backup.searches {
            let key = SearchEntry.normalize(s.query)
            guard !key.isEmpty, !haveSearches.contains(key) else { continue }
            let safeCount = SearchEntry.sanitizedCount(s.count)
            context.insert(SearchEntry(query: key, displayQuery: s.displayQuery ?? s.query,
                                       lastSearchedAt: s.lastSearchedAt, count: safeCount))
            haveSearches.insert(key)
            summary.searches += 1
        }

        let haveChannels = Set((try? context.fetch(FetchDescriptor<SubscribedChannel>()))?.map(\.channelID) ?? [])
        for c in backup.channels where !haveChannels.contains(c.channelID) {
            context.insert(SubscribedChannel(channelID: c.channelID, name: c.name,
                                             avatarURL: c.avatarURL, subscribedAt: c.subscribedAt))
            summary.channels += 1
        }

        let haveFeedback = Set((try? context.fetch(FetchDescriptor<Feedback>()))?.map(\.videoID) ?? [])
        for f in backup.feedback where !haveFeedback.contains(f.videoID) {
            context.insert(Feedback(videoID: f.videoID, signal: f.signal, title: f.title,
                                    uploader: f.uploader, category: f.category, tags: f.tags, createdAt: f.createdAt))
            summary.feedback += 1
        }

        let havePlaylists = Set((try? context.fetch(FetchDescriptor<Playlist>()))?.map(\.name) ?? [])
        for p in backup.playlists where !havePlaylists.contains(p.name) {
            let playlist = Playlist(name: p.name, createdAt: p.createdAt)
            context.insert(playlist)
            for v in p.videos {
                let pv = PlaylistVideo(videoID: v.videoID, title: v.title, uploader: v.uploader,
                                       thumbnailURL: v.thumbnailURL, duration: v.duration, addedAt: v.addedAt)
                pv.playlist = playlist
                context.insert(pv)
            }
            summary.playlists += 1
        }

        try? context.save()
        return summary
    }
}
