import Foundation
import SwiftData

enum BackupStore {
    static let maximumImportBytes = PersistedMetadataPolicy.maximumBackupBytes

    struct Limits {
        var maximumHistory = PersistedMetadataPolicy.maximumHistory
        var maximumSearches = PersistedMetadataPolicy.maximumSearches
        var maximumChannels = PersistedMetadataPolicy.maximumChannels
        var maximumPlaylists = PersistedMetadataPolicy.maximumPlaylists
        var maximumFeedback = PersistedMetadataPolicy.maximumFeedback
        var maximumVideosPerPlaylist = PersistedMetadataPolicy.maximumVideosPerPlaylist
        var maximumPlaylistVideos = PersistedMetadataPolicy.maximumPlaylistVideos
        var maximumTotalRecords = PersistedMetadataPolicy.maximumTotalRecords
    }

    struct Summary {
        var history = 0
        var searches = 0
        var channels = 0
        var playlists = 0
        var feedback = 0

        var text: String {
            "Imported \(history) history, \(searches) searches, \(channels) channels, "
                + "\(playlists) playlists, \(feedback) ratings."
        }
    }

    /// Write a JSON backup to a temp file and return its URL (for the share sheet).
    static func export(
        from context: ModelContext,
        maximumBytes: Int = PersistedMetadataPolicy.maximumBackupBytes
    ) throws -> URL {
        let backup = try makeBackup(from: context)

        do {
            try BackupValidator.validate(backup)
        } catch let error as BackupRestoreError {
            throw BackupExportError(error)
        }

        let data = try BackupFileCodec.encode(backup)
        try requireExportSize(data.count, maximumBytes: maximumBytes)
        return try BackupFileCodec.write(data)
    }

    static func requireExportSize(
        _ byteCount: Int,
        maximumBytes: Int = PersistedMetadataPolicy.maximumBackupBytes
    ) throws {
        guard maximumBytes >= 0, byteCount <= maximumBytes else {
            throw BackupExportError.encodedFileTooLarge(
                maximumBytes: max(0, maximumBytes)
            )
        }
    }

    /// Merge a backup into the current store. Existing rows (matched by their unique
    /// key) are kept as-is, so re-importing is safe and never duplicates.
    @discardableResult
    static func restore(
        from url: URL,
        into context: ModelContext,
        maximumBytes: Int = maximumImportBytes,
        limits: Limits = Limits()
    ) throws -> Summary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try BackupFileCodec.read(from: url, maximumBytes: maximumBytes)
        let backup = try BackupFileCodec.decode(data)
        try BackupValidator.validate(backup)
        return try BackupImporter.restore(backup, into: context, limits: limits)
    }

    private static func makeBackup(from context: ModelContext) throws -> AtlasBackup {
        let history = try context.fetch(FetchDescriptor<HistoryEntry>())
        let searches = try context.fetch(FetchDescriptor<SearchEntry>())
        let channels = try context.fetch(FetchDescriptor<SubscribedChannel>())
        let playlists = try context.fetch(FetchDescriptor<Playlist>())
        let feedback = try context.fetch(FetchDescriptor<Feedback>())

        return AtlasBackup(
            exportedAt: .now,
            history: history.map {
                .init(
                    videoID: $0.videoID,
                    title: $0.title,
                    uploader: $0.uploader,
                    thumbnailURL: $0.thumbnailURL,
                    watchedAt: $0.watchedAt,
                    positionSeconds: $0.positionSeconds,
                    durationSeconds: $0.durationSeconds
                )
            },
            searches: searches.map {
                .init(
                    query: $0.query,
                    displayQuery: $0.displayQuery,
                    lastSearchedAt: $0.lastSearchedAt,
                    count: $0.count
                )
            },
            channels: channels.map {
                .init(
                    channelID: $0.channelID,
                    name: $0.name,
                    avatarURL: $0.avatarURL,
                    subscribedAt: $0.subscribedAt
                )
            },
            playlists: playlists.map { playlist in
                .init(
                    name: playlist.name,
                    createdAt: playlist.createdAt,
                    videos: playlist.orderedVideos.map {
                        .init(
                            videoID: $0.videoID,
                            title: $0.title,
                            uploader: $0.uploader,
                            thumbnailURL: $0.thumbnailURL,
                            duration: $0.duration,
                            addedAt: $0.addedAt
                        )
                    }
                )
            },
            feedback: feedback.map {
                .init(
                    videoID: $0.videoID,
                    signal: $0.signal,
                    title: $0.title,
                    uploader: $0.uploader,
                    category: $0.category,
                    tags: $0.tags,
                    createdAt: $0.createdAt
                )
            }
        )
    }
}
