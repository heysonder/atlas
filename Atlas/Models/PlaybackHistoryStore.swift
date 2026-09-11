import Foundation
import PipedKit
import SwiftData

/// A playback request keeps this token for its lifetime. Remote progress never
/// seeks the active player; a remote removal invalidates only future writes.
@MainActor
final class PlaybackHistorySession {
    let videoID: String
    let id: String
    let startedAt: Date
    fileprivate let deletionMarker: String
    fileprivate var sequence = 0
    /// When this session last wrote the journal; periodic ticks are throttled against it.
    fileprivate var lastJournaledAt: Date?

    fileprivate init(videoID: String, id: String, startedAt: Date, deletionMarker: String) {
        self.videoID = videoID
        self.id = id
        self.startedAt = startedAt
        self.deletionMarker = deletionMarker
    }
}

@MainActor
enum PlaybackHistoryStore {
    static let minWatchSeconds: Double = 5
    /// A session's periodic ticks journal at most this often; the ticks between
    /// only update the entry (autosaved). Boundaries (`flush`) always journal.
    static var tickJournalInterval: TimeInterval = 30

    static func beginSession(
        videoID: String, in context: ModelContext, now: Date = .now
    ) -> PlaybackHistorySession? {
        do {
            try PersistedMetadataPolicy.requireIdentifier(videoID, field: "history.videoID")
            try PersistedMetadataPolicy.requireFiniteDate(now, field: "history.sessionStartedAt")
            return PlaybackHistorySession(
                videoID: videoID, id: UUID().uuidString.lowercased(), startedAt: now,
                deletionMarker: try LibrarySyncJournal.historySessionMarker(videoID: videoID, in: context))
        } catch { return nil }
    }

    static func savedPosition(for videoID: String, in context: ModelContext) -> Double? {
        let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == videoID })
        guard let entry = try? context.fetch(descriptor).first else { return nil }
        guard
            (try? PersistedMetadataPolicy.requirePlaybackNumber(
                entry.positionSeconds, field: "history.positionSeconds")) != nil,
            (try? PersistedMetadataPolicy.requirePlaybackNumber(
                entry.durationSeconds, field: "history.durationSeconds")) != nil
        else { return nil }
        if entry.durationSeconds > 0, entry.positionSeconds >= entry.durationSeconds - 10 { return nil }
        return entry.positionSeconds
    }

    @discardableResult
    static func remove(_ entries: [HistoryEntry], in context: ModelContext) -> Bool {
        do {
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                for entry in entries {
                    try LibraryDeletionJournal.record(
                        kind: .history, entityID: entry.videoID, in: context)
                    context.delete(entry)
                }
            }
            WatchedIDsMemo.noteMembershipChange()
            return true
        } catch { return false }
    }

    @discardableResult
    static func clear(in context: ModelContext) -> Bool {
        do {
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                try LibrarySyncJournal.clear(kind: .history, in: context)
            }
            WatchedIDsMemo.noteMembershipChange()
            return true
        } catch { return false }
    }

    /// `flush` marks a boundary (pause, stop, end of playback, background): the
    /// upload happens promptly. Periodic ticks leave it false and are batched into
    /// one upload per coalescing interval; the local write is durable either way.
    @discardableResult
    static func savePosition(
        _ seconds: Double, videoID: String, duration: Double?,
        session: PlaybackHistorySession? = nil, flush: Bool = false, in context: ModelContext
    ) -> Bool {
        guard seconds >= minWatchSeconds else { return false }
        do {
            try PersistedMetadataPolicy.requireIdentifier(videoID, field: "history.videoID")
            try PersistedMetadataPolicy.requirePlaybackNumber(seconds, field: "history.positionSeconds")
            // A live or still-loading item reports NaN/infinite duration; the position
            // is still worth keeping, so only the duration is dropped.
            let duration = PersistedMetadataPolicy.sanitizedPlaybackNumber(duration)
            guard try accepts(session, videoID: videoID, in: context) else { return false }
            let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == videoID })
            guard let entry = try context.fetch(descriptor).first else { return false }
            let wasWatched = entry.isWatched
            let now = Date()
            func mutate() {
                stamp(session, on: entry)
                entry.playbackSequence = min(entry.playbackSequence, Int.max - 1) + 1
                entry.positionSeconds = seconds
                if let duration, duration > 0 { entry.durationSeconds = duration }
                entry.watchedAt = now
            }
            let journalDue =
                flush || session == nil
                || session?.lastJournaledAt.map { now.timeIntervalSince($0) >= tickJournalInterval } ?? true
            if journalDue {
                // The full journal write (snapshot, causal metadata, durable save) is
                // too heavy for every 5 s tick; the entry itself is always current.
                try LibrarySyncJournal.transaction(in: context, captureChanges: false, coalesceSync: !flush) {
                    mutate()
                    try LibrarySyncJournal.capture(kind: .history, entityID: videoID, in: context)
                }
                session?.lastJournaledAt = now
            } else {
                mutate()
            }
            session?.sequence = entry.playbackSequence
            if entry.isWatched != wasWatched { WatchedIDsMemo.noteMembershipChange() }
            return true
        } catch { return false }
    }

    @discardableResult
    static func record(
        _ request: PlayRequest, detail: VideoDetail? = nil,
        session: PlaybackHistorySession? = nil, in context: ModelContext
    ) -> Bool {
        record(
            videoID: request.videoID, title: detail?.title ?? request.title,
            uploader: detail?.uploader ?? request.uploader,
            thumbnailURL: detail?.thumbnailURL ?? request.thumbnail,
            session: session, in: context)
    }

    @discardableResult
    static func record(
        videoID: String, title: String, uploader: String?, thumbnailURL: String?,
        session: PlaybackHistorySession? = nil, in context: ModelContext
    ) -> Bool {
        do {
            try PersistedMetadataPolicy.requireIdentifier(videoID, field: "history.videoID")
            try PersistedMetadataPolicy.requireText(title, field: "history.title")
            try PersistedMetadataPolicy.requireOptionalText(uploader, field: "history.uploader")
            try PersistedMetadataPolicy.requireOptionalURL(thumbnailURL, field: "history.thumbnailURL")
            guard try accepts(session, videoID: videoID, in: context) else { return false }
            let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == videoID })
            let existing = try context.fetch(descriptor).first
            if existing == nil {
                guard
                    try context.fetchCount(FetchDescriptor<HistoryEntry>())
                        < PersistedMetadataPolicy.maximumHistory,
                    PersistedMetadataCapacity.allowsAddingTopLevelRecord(in: context)
                else { return false }
            }
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                let entry =
                    existing
                    ?? HistoryEntry(
                        videoID: videoID, title: title, uploader: uploader, thumbnailURL: thumbnailURL)
                if existing == nil { context.insert(entry) }
                entry.title = title
                if let uploader { entry.uploader = uploader }
                if let thumbnailURL { entry.thumbnailURL = thumbnailURL }
                entry.watchedAt = .now
                stamp(session, on: entry)
                try LibrarySyncJournal.capture(kind: .history, entityID: videoID, in: context)
            }
            return true
        } catch { return false }
    }

    private static func accepts(
        _ session: PlaybackHistorySession?, videoID: String, in context: ModelContext
    ) throws -> Bool {
        guard let session else { return true }
        guard session.videoID == videoID else { return false }
        return try session.deletionMarker
            == LibrarySyncJournal.historySessionMarker(
                videoID: videoID, in: context)
    }

    private static func stamp(_ session: PlaybackHistorySession?, on entry: HistoryEntry) {
        if let session {
            if entry.playbackSessionID != session.id {
                entry.playbackSessionID = session.id
                entry.playbackSessionStartedAt = session.startedAt
                entry.playbackSequence = session.sequence
            }
        } else if entry.playbackSessionID == nil {
            entry.playbackSessionID = UUID().uuidString.lowercased()
            entry.playbackSessionStartedAt = entry.watchedAt
            entry.playbackSequence = 0
        }
    }
}
