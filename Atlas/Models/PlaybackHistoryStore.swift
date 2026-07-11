import AVFoundation
import PipedKit
import SwiftData

@MainActor
enum PlaybackHistoryStore {
    static let minWatchSeconds: Double = 5

    static func savedPosition(for videoID: String, in context: ModelContext) -> Double? {
        let descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { $0.videoID == videoID })
        guard let entry = try? context.fetch(descriptor).first else { return nil }
        guard
            (try? PersistedMetadataPolicy.requirePlaybackNumber(
                entry.positionSeconds, field: "history.positionSeconds")) != nil,
            (try? PersistedMetadataPolicy.requirePlaybackNumber(
                entry.durationSeconds, field: "history.durationSeconds")) != nil
        else {
            return nil
        }
        if entry.durationSeconds > 0, entry.positionSeconds >= entry.durationSeconds - 10 {
            return nil
        }
        return entry.positionSeconds
    }

    static func remove(_ entries: [HistoryEntry], in context: ModelContext) {
        for entry in entries {
            context.delete(entry)
        }
    }

    @discardableResult
    static func savePosition(
        _ seconds: Double, videoID: String, duration: Double?,
        in context: ModelContext
    ) -> Bool {
        guard seconds >= minWatchSeconds,
            (try? PersistedMetadataPolicy.requireIdentifier(
                videoID, field: "history.videoID")) != nil,
            (try? PersistedMetadataPolicy.requirePlaybackNumber(
                seconds, field: "history.positionSeconds")) != nil
        else { return false }
        if let duration,
            (try? PersistedMetadataPolicy.requirePlaybackNumber(
                duration, field: "history.durationSeconds")) == nil
        {
            return false
        }
        let descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { $0.videoID == videoID })
        guard let entry = try? context.fetch(descriptor).first else { return false }
        let wasWatched = entry.isWatched
        entry.positionSeconds = seconds
        if entry.durationSeconds == 0, let duration, duration > 0 {
            entry.durationSeconds = duration
        }
        entry.watchedAt = .now
        if entry.isWatched != wasWatched {
            WatchedIDsMemo.noteMembershipChange()
        }
        return true
    }

    @discardableResult
    static func record(
        _ request: PlayRequest, detail: VideoDetail? = nil,
        in context: ModelContext
    ) -> Bool {
        record(
            videoID: request.videoID,
            title: detail?.title ?? request.title,
            uploader: detail?.uploader ?? request.uploader,
            thumbnailURL: detail?.thumbnailURL ?? request.thumbnail,
            in: context)
    }

    @discardableResult
    static func record(
        videoID: String, title: String, uploader: String?,
        thumbnailURL: String?, in context: ModelContext
    ) -> Bool {
        do {
            try PersistedMetadataPolicy.requireIdentifier(videoID, field: "history.videoID")
            try PersistedMetadataPolicy.requireText(title, field: "history.title")
            try PersistedMetadataPolicy.requireOptionalText(uploader, field: "history.uploader")
            try PersistedMetadataPolicy.requireOptionalURL(
                thumbnailURL, field: "history.thumbnailURL")
        } catch {
            return false
        }
        let descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { $0.videoID == videoID })
        if let existing = try? context.fetch(descriptor).first {
            existing.watchedAt = .now
            return true
        } else {
            guard let count = try? context.fetchCount(FetchDescriptor<HistoryEntry>()),
                count < PersistedMetadataPolicy.maximumHistory,
                PersistedMetadataCapacity.allowsAddingTopLevelRecord(in: context)
            else {
                return false
            }
            context.insert(
                HistoryEntry(
                    videoID: videoID,
                    title: title,
                    uploader: uploader,
                    thumbnailURL: thumbnailURL))
            return true
        }
    }
}
