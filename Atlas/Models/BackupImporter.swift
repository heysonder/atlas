import SwiftData

enum BackupImporter {
    static func restore(
        _ backup: AtlasBackup,
        into context: ModelContext,
        limits: BackupStore.Limits
    ) throws -> BackupStore.Summary {
        let importContext = ModelContext(context.container)
        importContext.autosaveEnabled = false
        var summary = BackupStore.Summary()
        do {
            try importContext.transaction {
                try preflightMergedState(backup, in: importContext, limits: limits)
                summary = try merge(backup, into: importContext)
            }
        } catch let error as BackupRestoreError {
            throw error
        } catch {
            throw BackupRestoreError.cannotSave
        }
        return summary
    }

    private static func preflightMergedState(
        _ backup: AtlasBackup,
        in context: ModelContext,
        limits: BackupStore.Limits
    ) throws {
        let history = try context.fetch(FetchDescriptor<HistoryEntry>())
        let searches = try context.fetch(FetchDescriptor<SearchEntry>())
        let channels = try context.fetch(FetchDescriptor<SubscribedChannel>())
        let playlists = try context.fetch(FetchDescriptor<Playlist>())
        let feedback = try context.fetch(FetchDescriptor<Feedback>())
        let playlistVideos = try context.fetch(FetchDescriptor<PlaylistVideo>())

        let historyIDs = try uniqueValues(history.map(\.videoID), field: "existing.history")
        let searchKeys = try uniqueValues(
            searches.map { SearchEntry.normalize($0.query) },
            field: "existing.searches"
        )
        let channelIDs = try uniqueValues(
            channels.map(\.channelID),
            field: "existing.channels"
        )
        let feedbackIDs = try uniqueValues(
            feedback.map(\.videoID),
            field: "existing.feedback"
        )
        let playlistNames = try uniqueValues(
            playlists.map { PersistedMetadataPolicy.playlistNameKey($0.name) },
            field: "existing.playlists"
        )

        for (playlistIndex, playlist) in playlists.enumerated() {
            try requireCount(
                playlist.videos.count,
                maximum: limits.maximumVideosPerPlaylist,
                field: "existing.playlists[\(playlistIndex)].videos"
            )
            _ = try uniqueValues(
                playlist.videos.map(\.videoID),
                field: "existing.playlists[\(playlistIndex)].videos"
            )
        }

        let addedHistory = backup.history.count { !historyIDs.contains($0.videoID) }
        let addedSearches = backup.searches.count {
            !searchKeys.contains(SearchEntry.normalize($0.query))
        }
        let addedChannels = backup.channels.count { !channelIDs.contains($0.channelID) }
        let addedFeedback = backup.feedback.count { !feedbackIDs.contains($0.videoID) }
        let addedPlaylists = backup.playlists.filter {
            !playlistNames.contains(PersistedMetadataPolicy.playlistNameKey($0.name))
        }

        var addedPlaylistVideoCount = 0
        for (playlistIndex, playlist) in addedPlaylists.enumerated() {
            try requireCount(
                playlist.videos.count,
                maximum: limits.maximumVideosPerPlaylist,
                field: "added.playlists[\(playlistIndex)].videos"
            )
            addedPlaylistVideoCount = try checkedSum(
                addedPlaylistVideoCount,
                playlist.videos.count,
                maximum: limits.maximumPlaylistVideos,
                field: "playlists.videos"
            )
        }

        let mergedHistory = try checkedSum(
            history.count,
            addedHistory,
            maximum: limits.maximumHistory,
            field: "history"
        )
        let mergedSearches = try checkedSum(
            searches.count,
            addedSearches,
            maximum: limits.maximumSearches,
            field: "searches"
        )
        let mergedChannels = try checkedSum(
            channels.count,
            addedChannels,
            maximum: limits.maximumChannels,
            field: "channels"
        )
        let mergedPlaylists = try checkedSum(
            playlists.count,
            addedPlaylists.count,
            maximum: limits.maximumPlaylists,
            field: "playlists"
        )
        let mergedFeedback = try checkedSum(
            feedback.count,
            addedFeedback,
            maximum: limits.maximumFeedback,
            field: "feedback"
        )
        let mergedPlaylistVideos = try checkedSum(
            playlistVideos.count,
            addedPlaylistVideoCount,
            maximum: limits.maximumPlaylistVideos,
            field: "playlists.videos"
        )
        _ = try checkedSum(
            mergedHistory,
            mergedSearches,
            mergedChannels,
            mergedPlaylists,
            mergedFeedback,
            mergedPlaylistVideos,
            maximum: limits.maximumTotalRecords,
            field: "records"
        )
    }

    private static func uniqueValues(
        _ values: [String],
        field: String
    ) throws -> Set<String> {
        var result = Set<String>()
        for (index, value) in values.enumerated() {
            guard result.insert(value).inserted else {
                throw BackupRestoreError.duplicateValue(field: "\(field)[\(index)]")
            }
        }
        return result
    }

    private static func merge(
        _ backup: AtlasBackup,
        into context: ModelContext
    ) throws -> BackupStore.Summary {
        var summary = BackupStore.Summary()

        var haveHistory = Set(try context.fetch(FetchDescriptor<HistoryEntry>()).map(\.videoID))
        for history in backup.history where !haveHistory.contains(history.videoID) {
            context.insert(
                HistoryEntry(
                    videoID: history.videoID,
                    title: history.title,
                    uploader: history.uploader,
                    thumbnailURL: history.thumbnailURL,
                    watchedAt: history.watchedAt,
                    positionSeconds: history.positionSeconds,
                    durationSeconds: history.durationSeconds
                )
            )
            haveHistory.insert(history.videoID)
            summary.history += 1
        }

        var haveSearches = Set(
            try context.fetch(FetchDescriptor<SearchEntry>()).map {
                SearchEntry.normalize($0.query)
            })
        for search in backup.searches {
            let key = SearchEntry.normalize(search.query)
            guard !key.isEmpty, !haveSearches.contains(key) else { continue }
            context.insert(
                SearchEntry(
                    query: key,
                    displayQuery: search.displayQuery ?? search.query,
                    lastSearchedAt: search.lastSearchedAt,
                    count: search.count
                )
            )
            haveSearches.insert(key)
            summary.searches += 1
        }

        var haveChannels = Set(
            try context.fetch(FetchDescriptor<SubscribedChannel>()).map(\.channelID)
        )
        for channel in backup.channels where !haveChannels.contains(channel.channelID) {
            context.insert(
                SubscribedChannel(
                    channelID: channel.channelID,
                    name: channel.name,
                    avatarURL: channel.avatarURL,
                    subscribedAt: channel.subscribedAt
                )
            )
            haveChannels.insert(channel.channelID)
            summary.channels += 1
        }

        var haveFeedback = Set(
            try context.fetch(FetchDescriptor<Feedback>()).map(\.videoID)
        )
        for feedback in backup.feedback where !haveFeedback.contains(feedback.videoID) {
            context.insert(
                Feedback(
                    videoID: feedback.videoID,
                    signal: feedback.signal,
                    title: feedback.title,
                    uploader: feedback.uploader,
                    category: feedback.category,
                    tags: feedback.tags,
                    createdAt: feedback.createdAt
                )
            )
            haveFeedback.insert(feedback.videoID)
            summary.feedback += 1
        }

        var havePlaylists = Set(
            try context.fetch(FetchDescriptor<Playlist>()).map {
                PersistedMetadataPolicy.playlistNameKey($0.name)
            })
        for playlistDTO in backup.playlists {
            let nameKey = PersistedMetadataPolicy.playlistNameKey(playlistDTO.name)
            guard !havePlaylists.contains(nameKey) else { continue }
            let playlist = Playlist(name: playlistDTO.name, createdAt: playlistDTO.createdAt)
            context.insert(playlist)
            for video in playlistDTO.videos {
                let playlistVideo = PlaylistVideo(
                    videoID: video.videoID,
                    title: video.title,
                    uploader: video.uploader,
                    thumbnailURL: video.thumbnailURL,
                    duration: video.duration,
                    addedAt: video.addedAt
                )
                playlistVideo.playlist = playlist
                context.insert(playlistVideo)
            }
            havePlaylists.insert(nameKey)
            summary.playlists += 1
        }

        return summary
    }

    private static func requireCount(
        _ count: Int,
        maximum: Int,
        field: String
    ) throws {
        do {
            try PersistedMetadataPolicy.requireCount(count, maximum: maximum, field: field)
        } catch let violation as PersistedMetadataPolicy.Violation {
            throw restoreError(for: violation)
        }
    }

    private static func checkedSum(
        _ values: Int...,
        maximum: Int,
        field: String
    ) throws -> Int {
        do {
            var total = 0
            for value in values {
                total = try PersistedMetadataPolicy.checkedSum(
                    total,
                    value,
                    maximum: maximum,
                    field: field
                )
            }
            return total
        } catch let violation as PersistedMetadataPolicy.Violation {
            throw restoreError(for: violation)
        }
    }

    private static func restoreError(
        for violation: PersistedMetadataPolicy.Violation
    ) -> BackupRestoreError {
        switch violation {
        case .invalidValue(let field):
            .invalidValue(field: field)
        case .limitExceeded(let field, let maximum):
            .limitExceeded(field: field, maximum: maximum)
        case .duplicateValue(let field):
            .duplicateValue(field: field)
        }
    }
}
