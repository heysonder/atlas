import Foundation
import SwiftData

enum BackupImporter {
    static func restore(
        _ backup: AtlasBackup,
        into context: ModelContext,
        limits: BackupStore.Limits
    ) throws -> BackupStore.Summary {
        // Validate before committing any pending UI work. Import through the
        // context that owns the foreground journal so a cached counter/register
        // cannot lag behind a second context's restore.
        let playlistIDs = try preflightMergedState(backup, in: context, limits: limits)
        if context.hasChanges {
            do {
                try LibrarySyncJournal.flushPendingChanges(in: context)
            } catch {
                throw BackupRestoreError.cannotSavePendingChanges
            }
        }
        var summary = BackupStore.Summary()
        do {
            try LibrarySyncJournal.transaction(in: context) {
                try PlaylistStore.adoptLegacyFavorites(in: context)
                summary = try merge(backup, playlistIDs: playlistIDs, into: context)
                try RecommendationProfileStore.invalidate(in: context)
            }
        } catch let error as BackupRestoreError {
            throw error
        } catch {
            throw BackupRestoreError.cannotSave
        }
        WatchedIDsMemo.noteMembershipChange()
        return summary
    }

    private static func preflightMergedState(
        _ backup: AtlasBackup,
        in context: ModelContext,
        limits: BackupStore.Limits
    ) throws -> [UUID] {
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
        _ = try uniqueValues(
            playlists.map { $0.id.uuidString },
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
        let playlistIDs = try playlistDestinations(backup.playlists, existing: playlists)
        let existingPlaylistIDs = Set(playlists.map(canonicalPlaylistID))
        let addedPlaylistIDs = Set(playlistIDs).subtracting(existingPlaylistIDs)
        var mergedVideoIDs: [UUID: Set<String>] = [:]
        for playlist in playlists {
            mergedVideoIDs[canonicalPlaylistID(playlist), default: []]
                .formUnion(playlist.videos.map(\.videoID))
        }
        // Adoption unions duplicate legacy Favorites memberships. Preserve any
        // unattached rows in the capacity count even though imports never add them.
        let attachedVideoCount = playlists.reduce(0) { $0 + $1.videos.count }
        let projectedExistingVideoCount =
            playlistVideos.count - attachedVideoCount
            + mergedVideoIDs.values.reduce(0) { $0 + $1.count }
        for videoIDs in mergedVideoIDs.values {
            try requireCount(
                videoIDs.count, maximum: limits.maximumVideosPerPlaylist, field: "existing.playlists.videos")
        }
        var addedPlaylistVideoCount = 0
        for (playlistIndex, playlist) in backup.playlists.enumerated() {
            let destination = playlistIDs[playlistIndex]
            let existingIDs = mergedVideoIDs[destination] ?? []
            let mergedIDs = existingIDs.union(playlist.videos.map(\.videoID))
            mergedVideoIDs[destination] = mergedIDs
            try requireCount(
                mergedIDs.count,
                maximum: limits.maximumVideosPerPlaylist,
                field: "playlists[\(playlistIndex)].videos"
            )
            addedPlaylistVideoCount = try checkedSum(
                addedPlaylistVideoCount,
                mergedIDs.count - existingIDs.count,
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
            existingPlaylistIDs.count,
            addedPlaylistIDs.count,
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
            projectedExistingVideoCount,
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
        return playlistIDs
    }

    /// Resolve once during preflight and reuse the IDs while writing. Looking up
    /// by name during the merge could silently target the first of two libraries
    /// that independently created an identically named playlist.
    private static func playlistDestinations(
        _ incoming: [AtlasBackup.PlaylistDTO],
        existing: [Playlist]
    ) throws -> [UUID] {
        var namesByID: [UUID: String] = [:]
        for playlist in existing {
            let id = canonicalPlaylistID(playlist)
            namesByID[id] =
                id == PlaylistStore.favoritesPlaylistID
                ? PersistedMetadataPolicy.playlistNameKey(PlaylistStore.favoritesPlaylistName)
                : PersistedMetadataPolicy.playlistNameKey(playlist.name)
        }
        var result: [UUID] = []
        for playlist in incoming {
            let destination: UUID
            let isLegacyFavorite =
                playlist.systemKind == nil
                && PersistedMetadataPolicy.playlistNameKey(playlist.name)
                    == PersistedMetadataPolicy.playlistNameKey(PlaylistStore.favoritesPlaylistName)
            if playlist.systemKind == PlaylistStore.favoritesSystemKind || isLegacyFavorite {
                destination = PlaylistStore.favoritesPlaylistID
            } else if let id = playlist.id {
                let matches = Set(
                    existing.filter { $0.id == id || ($0.legacyIDs ?? []).contains(id) }
                        .map(canonicalPlaylistID))
                guard matches.count <= 1 else {
                    throw BackupRestoreError.duplicateValue(field: "existing.playlists.id")
                }
                destination = matches.first ?? id
            } else {
                let name = PersistedMetadataPolicy.playlistNameKey(playlist.name)
                let matches = namesByID.filter { $0.value == name }.map(\.key)
                guard matches.count <= 1 else {
                    throw BackupRestoreError.ambiguousPlaylist(name: playlist.name)
                }
                destination = matches.first ?? UUID()
            }
            namesByID[destination] =
                namesByID[destination]
                ?? PersistedMetadataPolicy.playlistNameKey(playlist.name)
            result.append(destination)
        }
        return result
    }

    private static func canonicalPlaylistID(_ playlist: Playlist) -> UUID {
        if playlist.systemKind == PlaylistStore.favoritesSystemKind
            || (playlist.systemKind == nil
                && PersistedMetadataPolicy.playlistNameKey(playlist.name)
                    == PersistedMetadataPolicy.playlistNameKey(PlaylistStore.favoritesPlaylistName))
        {
            return PlaylistStore.favoritesPlaylistID
        }
        return playlist.id
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
        playlistIDs: [UUID],
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

        var havePlaylists = Dictionary(
            uniqueKeysWithValues:
                try context.fetch(FetchDescriptor<Playlist>()).map { ($0.id, $0) })
        for (index, playlistDTO) in backup.playlists.enumerated() {
            let id = playlistIDs[index]
            let playlist: Playlist
            var changed = false
            if let existing = havePlaylists[id] {
                playlist = existing
            } else {
                // An explicit restore may revive the parent, but stale offline
                // members from its deleted incarnation must remain suppressed.
                var incarnation: String?
                if let state = try SyncStoreAdapter(context: context).state(
                    kind: .playlist, entityID: id.uuidString.lowercased()),
                    try SyncPayload.decode(SyncEnvelope.self, from: state.envelopeData).isTombstone
                {
                    incarnation = UUID().uuidString.lowercased()
                }
                playlist = Playlist(
                    id: id, name: playlistDTO.name, createdAt: playlistDTO.createdAt,
                    systemKind: id == PlaylistStore.favoritesPlaylistID
                        ? PlaylistStore.favoritesSystemKind : playlistDTO.systemKind,
                    syncIncarnation: incarnation)
                context.insert(playlist)
                havePlaylists[id] = playlist
                changed = true
            }
            if id == PlaylistStore.favoritesPlaylistID, let importedID = playlistDTO.id,
                importedID != id, !(playlist.legacyIDs ?? []).contains(importedID)
            {
                playlist.legacyIDs = ((playlist.legacyIDs ?? []) + [importedID])
                    .sorted { $0.uuidString < $1.uuidString }
                changed = true
            }
            var existingVideoIDs = Set(playlist.videos.map(\.videoID))
            for video in playlistDTO.videos where !existingVideoIDs.contains(video.videoID) {
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
                existingVideoIDs.insert(video.videoID)
                changed = true
            }
            if changed { summary.playlists += 1 }
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
