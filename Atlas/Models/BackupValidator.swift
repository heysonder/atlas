import Foundation

enum BackupValidator {
    static func validate(_ backup: AtlasBackup) throws {
        guard (1...2).contains(backup.version) else {
            throw BackupRestoreError.unsupportedVersion(backup.version)
        }
        try requireCount(
            backup.history.count,
            maximum: PersistedMetadataPolicy.maximumHistory,
            field: "history"
        )
        try requireCount(
            backup.searches.count,
            maximum: PersistedMetadataPolicy.maximumSearches,
            field: "searches"
        )
        try requireCount(
            backup.channels.count,
            maximum: PersistedMetadataPolicy.maximumChannels,
            field: "channels"
        )
        try requireCount(
            backup.playlists.count,
            maximum: PersistedMetadataPolicy.maximumPlaylists,
            field: "playlists"
        )
        try requireCount(
            backup.feedback.count,
            maximum: PersistedMetadataPolicy.maximumFeedback,
            field: "feedback"
        )
        try requireFiniteDate(backup.exportedAt, field: "exportedAt")

        var playlistVideoCount = 0
        for (index, playlist) in backup.playlists.enumerated() {
            try requireCount(
                playlist.videos.count,
                maximum: PersistedMetadataPolicy.maximumVideosPerPlaylist,
                field: "playlists[\(index)].videos"
            )
            playlistVideoCount = try checkedSum(
                playlistVideoCount,
                playlist.videos.count,
                maximum: PersistedMetadataPolicy.maximumPlaylistVideos,
                field: "playlists.videos"
            )
        }
        try requireCount(
            playlistVideoCount,
            maximum: PersistedMetadataPolicy.maximumPlaylistVideos,
            field: "playlists.videos"
        )
        _ = try checkedSum(
            backup.history.count,
            backup.searches.count,
            backup.channels.count,
            backup.playlists.count,
            backup.feedback.count,
            playlistVideoCount,
            maximum: PersistedMetadataPolicy.maximumTotalRecords,
            field: "records"
        )

        try validateHistory(backup.history)
        try validateSearches(backup.searches)
        try validateChannels(backup.channels)
        try validatePlaylists(backup.playlists)
        try validateFeedback(backup.feedback)
    }

    private static func validateHistory(_ history: [AtlasBackup.HistoryDTO]) throws {
        var historyIDs = Set<String>()
        for (index, row) in history.enumerated() {
            let field = "history[\(index)]"
            try requireIdentifier(row.videoID, field: field + ".videoID")
            guard historyIDs.insert(row.videoID).inserted else {
                throw BackupRestoreError.duplicateValue(field: field + ".videoID")
            }
            try requireText(row.title, field: field + ".title")
            try requireOptionalText(row.uploader, field: field + ".uploader")
            try requireOptionalURL(row.thumbnailURL, field: field + ".thumbnailURL")
            try requireFiniteDate(row.watchedAt, field: field + ".watchedAt")
            try requirePlaybackNumber(row.positionSeconds, field: field + ".positionSeconds")
            try requirePlaybackNumber(row.durationSeconds, field: field + ".durationSeconds")
        }
    }

    private static func validateSearches(_ searches: [AtlasBackup.SearchDTO]) throws {
        var searchKeys = Set<String>()
        for (index, row) in searches.enumerated() {
            let field = "searches[\(index)]"
            let key = SearchEntry.normalize(row.query)
            try requireIdentifier(key, field: field + ".query")
            guard searchKeys.insert(key).inserted else {
                throw BackupRestoreError.duplicateValue(field: field + ".query")
            }
            try requireText(row.query, field: field + ".query")
            try requireOptionalText(row.displayQuery, field: field + ".displayQuery")
            try requireFiniteDate(row.lastSearchedAt, field: field + ".lastSearchedAt")
            guard (1...SearchEntry.maximumCount).contains(row.count) else {
                throw BackupRestoreError.invalidValue(field: field + ".count")
            }
        }
    }

    private static func validateChannels(_ channels: [AtlasBackup.ChannelDTO]) throws {
        var channelIDs = Set<String>()
        for (index, row) in channels.enumerated() {
            let field = "channels[\(index)]"
            try requireIdentifier(row.channelID, field: field + ".channelID")
            guard channelIDs.insert(row.channelID).inserted else {
                throw BackupRestoreError.duplicateValue(field: field + ".channelID")
            }
            try requireText(row.name, field: field + ".name")
            try requireOptionalURL(row.avatarURL, field: field + ".avatarURL")
            try requireFiniteDate(row.subscribedAt, field: field + ".subscribedAt")
        }
    }

    private static func validatePlaylists(_ playlists: [AtlasBackup.PlaylistDTO]) throws {
        var playlistNames = Set<String>()
        for (playlistIndex, row) in playlists.enumerated() {
            let field = "playlists[\(playlistIndex)]"
            try requireNonemptyText(row.name, field: field + ".name")
            let nameKey = PersistedMetadataPolicy.playlistNameKey(row.name)
            guard playlistNames.insert(nameKey).inserted else {
                throw BackupRestoreError.duplicateValue(field: field + ".name")
            }
            try requireFiniteDate(row.createdAt, field: field + ".createdAt")
            try validatePlaylistVideos(row.videos, field: field)
        }
    }

    private static func validatePlaylistVideos(
        _ videos: [AtlasBackup.PlaylistDTO.VideoDTO],
        field: String
    ) throws {
        var videoIDs = Set<String>()
        for (videoIndex, video) in videos.enumerated() {
            let videoField = field + ".videos[\(videoIndex)]"
            try requireIdentifier(video.videoID, field: videoField + ".videoID")
            guard videoIDs.insert(video.videoID).inserted else {
                throw BackupRestoreError.duplicateValue(field: videoField + ".videoID")
            }
            try requireText(video.title, field: videoField + ".title")
            try requireOptionalText(video.uploader, field: videoField + ".uploader")
            try requireOptionalURL(video.thumbnailURL, field: videoField + ".thumbnailURL")
            try requirePlaybackDuration(video.duration, field: videoField + ".duration")
            try requireFiniteDate(video.addedAt, field: videoField + ".addedAt")
        }
    }

    private static func validateFeedback(_ feedback: [AtlasBackup.FeedbackDTO]) throws {
        var feedbackIDs = Set<String>()
        for (index, row) in feedback.enumerated() {
            let field = "feedback[\(index)]"
            try requireIdentifier(row.videoID, field: field + ".videoID")
            guard feedbackIDs.insert(row.videoID).inserted else {
                throw BackupRestoreError.duplicateValue(field: field + ".videoID")
            }
            guard row.signal == -1 || row.signal == 1 else {
                throw BackupRestoreError.invalidValue(field: field + ".signal")
            }
            try requireText(row.title, field: field + ".title")
            try requireOptionalText(row.uploader, field: field + ".uploader")
            try requireOptionalText(row.category, field: field + ".category")
            try requireFiniteDate(row.createdAt, field: field + ".createdAt")
            if let tags = row.tags {
                try requireCount(
                    tags.count,
                    maximum: PersistedMetadataPolicy.maximumTags,
                    field: field + ".tags"
                )
                try mapViolation {
                    try PersistedMetadataPolicy.requireTags(tags, field: field + ".tags")
                }
            }
        }
    }

    private static func requireCount(_ count: Int, maximum: Int, field: String) throws {
        try mapViolation {
            try PersistedMetadataPolicy.requireCount(count, maximum: maximum, field: field)
        }
    }

    private static func requireIdentifier(_ value: String, field: String) throws {
        try mapViolation {
            try PersistedMetadataPolicy.requireIdentifier(value, field: field)
        }
    }

    private static func requireNonemptyText(_ value: String, field: String) throws {
        try mapViolation {
            try PersistedMetadataPolicy.requireNonemptyText(value, field: field)
        }
    }

    private static func requireText(_ value: String, field: String) throws {
        try mapViolation {
            try PersistedMetadataPolicy.requireText(value, field: field)
        }
    }

    private static func requireOptionalText(_ value: String?, field: String) throws {
        try mapViolation {
            try PersistedMetadataPolicy.requireOptionalText(value, field: field)
        }
    }

    private static func requireOptionalURL(_ value: String?, field: String) throws {
        try mapViolation {
            try PersistedMetadataPolicy.requireOptionalURL(value, field: field)
        }
    }

    private static func requireFiniteDate(_ value: Date, field: String) throws {
        try mapViolation {
            try PersistedMetadataPolicy.requireFiniteDate(value, field: field)
        }
    }

    private static func requirePlaybackNumber(_ value: Double, field: String) throws {
        try mapViolation {
            try PersistedMetadataPolicy.requirePlaybackNumber(value, field: field)
        }
    }

    private static func requirePlaybackDuration(_ value: Int, field: String) throws {
        try mapViolation {
            try PersistedMetadataPolicy.requirePlaybackDuration(value, field: field)
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

    private static func mapViolation(_ operation: () throws -> Void) throws {
        do {
            try operation()
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
