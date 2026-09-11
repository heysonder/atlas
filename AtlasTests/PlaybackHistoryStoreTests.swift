import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func playbackHistoryStoreIgnoresFinishedResumePositions() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let entry = HistoryEntry(
        videoID: "v1", title: "One",
        positionSeconds: 95, durationSeconds: 100)
    context.insert(entry)

    #expect(PlaybackHistoryStore.savedPosition(for: "v1", in: context) == nil)

    PlaybackHistoryStore.savePosition(40, videoID: "v1", duration: 100, in: context)
    #expect(PlaybackHistoryStore.savedPosition(for: "v1", in: context) == 40)

    entry.positionSeconds = Double(PersistedMetadataPolicy.maximumPlaybackSeconds + 1)
    #expect(PlaybackHistoryStore.savedPosition(for: "v1", in: context) == nil)
    entry.positionSeconds = 40
    entry.durationSeconds = Double(PersistedMetadataPolicy.maximumPlaybackSeconds + 1)
    #expect(PlaybackHistoryStore.savedPosition(for: "v1", in: context) == nil)
}

@MainActor
@Test func watchedIDsMemoIgnoresProgressWritesUntilMembershipChanges() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let entry = HistoryEntry(
        videoID: "v1", title: "One",
        positionSeconds: 20, durationSeconds: 100)
    context.insert(entry)
    let memo = WatchedIDsMemo()
    let history = [entry]

    #expect(memo.ids(for: history).isEmpty)
    #expect(memo.rebuildCount == 1)

    #expect(PlaybackHistoryStore.savePosition(40, videoID: "v1", duration: 100, in: context))
    #expect(memo.ids(for: history).isEmpty)
    #expect(memo.rebuildCount == 1)

    #expect(PlaybackHistoryStore.savePosition(80, videoID: "v1", duration: 100, in: context))
    #expect(memo.ids(for: history) == ["v1"])
    #expect(memo.rebuildCount == 2)
}

@MainActor
@Test func periodicProgressTicksJournalOncePerIntervalAndBoundariesAlways() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let previousInterval = PlaybackHistoryStore.tickJournalInterval
    defer { PlaybackHistoryStore.tickJournalInterval = previousInterval }
    PlaybackHistoryStore.tickJournalInterval = 3_600
    #expect(PlaybackHistoryStore.record(videoID: "v1", title: "One", uploader: nil, thumbnailURL: nil, in: context))
    let adapter = SyncStoreAdapter(context: context)
    func journaledPosition() throws -> Double {
        let state = try #require(try adapter.state(kind: .history, entityID: "v1"))
        return try SyncPayload.decode(SyncHistoryPayload.self, from: #require(state.materializedPayload))
            .positionSeconds
    }
    let session = PlaybackHistoryStore.beginSession(videoID: "v1", in: context)

    #expect(PlaybackHistoryStore.savePosition(10, videoID: "v1", duration: 100, session: session, in: context))
    #expect(try journaledPosition() == 10)
    // Ticks inside the interval update the entry but not the journal.
    #expect(PlaybackHistoryStore.savePosition(15, videoID: "v1", duration: 100, session: session, in: context))
    #expect(PlaybackHistoryStore.savePosition(20, videoID: "v1", duration: 100, session: session, in: context))
    #expect(PlaybackHistoryStore.savedPosition(for: "v1", in: context) == 20)
    #expect(try journaledPosition() == 10)
    // A boundary (pause, stop, background) journals the latest position.
    #expect(
        PlaybackHistoryStore.savePosition(
            25, videoID: "v1", duration: 100, session: session, flush: true, in: context))
    #expect(try journaledPosition() == 25)
}
