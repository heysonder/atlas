import Foundation
import SwiftData
import Testing

@testable import Atlas

// Piped reports -1 for live streams and older rows stored it verbatim. A duration is
// display metadata, so an unusable value must not block an export, a sync capture,
// a playlist save, or a history position write.

@MainActor
@Suite(.serialized)
struct InvalidDurationToleranceTests {

    private func makeLibraryWithLiveRow() throws -> (ModelContainer, PlaylistVideo) {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = try #require(PlaylistStore.createPlaylist(named: "Live", in: context))
        let row = PlaylistVideo(videoID: "live-video", title: "Live show", duration: -1)
        row.playlist = playlist
        context.insert(row)
        try context.save()
        return (container, row)
    }

    @Test func exportToleratesALegacyLiveStreamDuration() throws {
        let (container, _) = try makeLibraryWithLiveRow()
        let url = try BackupStore.export(from: container.mainContext)
        let target = try makeTestContainer()
        _ = try BackupStore.restore(from: url, into: target.mainContext)
        let restored = try target.mainContext.fetch(FetchDescriptor<PlaylistVideo>())
        #expect(restored.first?.videoID == "live-video")
        #expect(restored.first?.duration == 0)
    }

    @Test func syncCaptureToleratesALegacyLiveStreamDuration() throws {
        let (container, row) = try makeLibraryWithLiveRow()
        let context = container.mainContext
        let playlist = try #require(row.playlist)
        let identity = LibrarySyncJournal.playlistVideoIdentity(
            playlistID: playlist.id, videoID: row.videoID, incarnation: playlist.syncIncarnation)
        try LibrarySyncJournal.transaction(in: context, captureChanges: false, notifySync: false) {
            try LibrarySyncJournal.capture(kind: .playlistVideo, entityID: identity, in: context)
        }
        let pending = try SyncStoreAdapter(context: context).pendingRecords()
        let record = try #require(pending.first { $0.envelope.entityID == identity })
        let payload = try SyncPayload.decode(
            SyncPlaylistVideoPayload.self, from: #require(record.envelope.effectivePayload))
        #expect(payload.duration == 0)
    }

    @Test func savingALiveStreamToAPlaylistStoresAnUnknownDuration() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let snapshot = PlaylistVideoSnapshot(videoID: "live-now", title: "Live now", duration: -1)
        #expect(snapshot.duration == 0)
        let playlist = try #require(PlaylistStore.createPlaylist(named: "Saved", in: context))
        #expect(PlaylistStore.add(snapshot, to: playlist, in: context) != .missing)
        #expect(PlaylistStore.containsVideoID("live-now", in: playlist))
    }

    @Test func positionIsSavedWhenTheDurationIsIndefinite() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        #expect(
            PlaybackHistoryStore.record(
                videoID: "live-history", title: "Live history", uploader: nil, thumbnailURL: nil, in: context))
        #expect(
            PlaybackHistoryStore.savePosition(42, videoID: "live-history", duration: .nan, in: context))
        let entry = try #require(
            try context.fetch(FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == "live-history" }))
                .first)
        #expect(entry.positionSeconds == 42)
        #expect(entry.durationSeconds == 0)
    }
}
