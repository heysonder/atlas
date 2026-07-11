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
