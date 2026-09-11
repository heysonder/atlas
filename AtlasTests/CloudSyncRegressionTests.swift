import Foundation
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func historyReceivedBeforeItsClearPolicyReplacesOlderLocalRowAfterPolicyArrives() throws {
    let source = try makeTestContainer()
    let destination = try makeTestContainer()
    let sourceContext = source.mainContext
    let destinationContext = destination.mainContext
    sourceContext.autosaveEnabled = false
    destinationContext.autosaveEnabled = false
    let sourceAdapter = SyncStoreAdapter(context: sourceContext)
    let destinationAdapter = SyncStoreAdapter(context: destinationContext)

    let oldSession = try #require(PlaybackHistoryStore.beginSession(videoID: "same-video", in: destinationContext))
    #expect(
        PlaybackHistoryStore.record(
            videoID: "same-video", title: "Before clear", uploader: nil, thumbnailURL: nil,
            session: oldSession, in: destinationContext))
    #expect(
        PlaybackHistoryStore.savePosition(
            400, videoID: "same-video", duration: 1_000, session: oldSession, in: destinationContext))
    let oldEnvelope = try regressionEnvelope(.history, id: "same-video", in: destinationContext)
    try sourceAdapter.apply(oldEnvelope)

    #expect(PlaybackHistoryStore.clear(in: sourceContext))
    let clearPolicy = try regressionEnvelope(.policy, id: SyncKind.history.rawValue, in: sourceContext)
    let newSession = try #require(PlaybackHistoryStore.beginSession(videoID: "same-video", in: sourceContext))
    #expect(
        PlaybackHistoryStore.record(
            videoID: "same-video", title: "After clear", uploader: nil, thumbnailURL: nil,
            session: newSession, in: sourceContext))
    #expect(
        PlaybackHistoryStore.savePosition(
            12, videoID: "same-video", duration: 900, session: newSession, in: sourceContext))
    let newEnvelope = try regressionEnvelope(.history, id: "same-video", in: sourceContext)
    #expect(newEnvelope.generation != oldEnvelope.generation)

    // CloudKit record ordering can put new-generation content in an earlier page.
    try destinationAdapter.apply(newEnvelope)
    #expect(try destinationContext.fetch(FetchDescriptor<HistoryEntry>()).first?.positionSeconds == 400)
    #expect(try destinationAdapter.generation(for: .history) == "initial")
    try destinationAdapter.apply(clearPolicy)

    let reader = ModelContext(destination)
    let rows = try reader.fetch(FetchDescriptor<HistoryEntry>())
    #expect(rows.count == 1)
    #expect(rows.first?.title == "After clear")
    #expect(rows.first?.positionSeconds == 12)
    #expect(rows.first?.durationSeconds == 900)
    #expect(rows.first?.playbackSessionID == newSession.id)
    #expect(try destinationAdapter.generation(for: .history) == newEnvelope.generation)

    // Neither a duplicate page nor an offline upload from before clear revives the old row.
    try destinationAdapter.apply(oldEnvelope)
    try destinationAdapter.apply(newEnvelope)
    try destinationAdapter.apply(clearPolicy)
    #expect(try destinationContext.fetchCount(FetchDescriptor<HistoryEntry>()) == 1)
    #expect(try destinationContext.fetch(FetchDescriptor<HistoryEntry>()).first?.positionSeconds == 12)
}

@MainActor
@Test func firstSearchesConvergeAcrossThreeReplicasWithoutCountingMergedTotalsAgain() throws {
    let containers = try (0..<3).map { _ in try makeTestContainer() }
    let contexts = containers.map(\.mainContext)
    let adapters = contexts.map { SyncStoreAdapter(context: $0) }
    for context in contexts {
        context.autosaveEnabled = false
        #expect(SearchHistoryStore.record("Shared Query", in: context)?.count == 1)
    }
    let installations = try adapters.map { try $0.enrollment().installationID }
    #expect(Set(installations).count == 3)
    let initial = try contexts.map { try regressionEnvelope(.search, id: "shared query", in: $0) }

    try adapters[0].apply(initial[1])
    try adapters[1].apply(initial[2])
    try adapters[2].apply(initial[0])
    let partiallyMerged = try contexts.map { try regressionEnvelope(.search, id: "shared query", in: $0) }
    for index in 0..<3 {
        #expect(try contexts[index].fetch(FetchDescriptor<SearchEntry>()).first?.count == 2)
        try adapters[index].apply(partiallyMerged[(index + 1) % 3])
        #expect(try contexts[index].fetch(FetchDescriptor<SearchEntry>()).first?.count == 3)
    }

    let converged = try contexts.map { try regressionEnvelope(.search, id: "shared query", in: $0) }
    for adapter in adapters {
        for envelope in initial + partiallyMerged + converged {
            try adapter.apply(envelope)
        }
    }
    for context in contexts {
        #expect(try context.fetchCount(FetchDescriptor<SearchEntry>()) == 1)
        #expect(try context.fetch(FetchDescriptor<SearchEntry>()).first?.count == 3)
    }

    #expect(SearchHistoryStore.record("shared query", in: contexts[2])?.count == 4)
    let fourthSearch = try regressionEnvelope(.search, id: "shared query", in: contexts[2])
    for adapter in adapters {
        try adapter.apply(fourthSearch)
        try adapter.apply(fourthSearch)
    }
    for context in contexts {
        #expect(try context.fetch(FetchDescriptor<SearchEntry>()).first?.count == 4)
    }
}

@MainActor
@Test func delayedImpressionBaselineClearDoesNotEraseActivityCreatedAfterReset() throws {
    let source = try makeTestContainer()
    let destination = try makeTestContainer()
    let sourceContext = source.mainContext
    let destinationContext = destination.mainContext
    sourceContext.autosaveEnabled = false
    destinationContext.autosaveEnabled = false
    let sourceAdapter = SyncStoreAdapter(context: sourceContext)
    let destinationAdapter = SyncStoreAdapter(context: destinationContext)
    let earlier = Date.now.addingTimeInterval(-60)
    sourceContext.insert(FeedImpressionEntry(videoID: "legacy-video", count: 4, lastShownAt: earlier))
    try sourceContext.save()
    // Enrollment journals migrated aggregates before normal per-event mutations begin.
    try sourceAdapter.bootstrapLocalRecords()
    let oldID = try #require(
        RecommendationOutcomeStore.record(
            [
                .init(videoID: "old-video", position: 0, features: RecommendationSyncFeatures.empty.features)
            ], in: sourceContext, now: earlier)["old-video"])
    let baseline = try #require(sourceContext.fetch(FetchDescriptor<FeedImpressionBaseline>()).first)
    try destinationAdapter.apply(regressionEnvelope(.activity, id: oldID.uuidString.lowercased(), in: sourceContext))
    try destinationAdapter.apply(
        regressionEnvelope(.impressionBaseline, id: baseline.id.uuidString.lowercased(), in: sourceContext))
    #expect(try destinationContext.fetchCount(FetchDescriptor<RecommendationOutcomeEntry>()) == 1)
    #expect(try destinationContext.fetchCount(FetchDescriptor<FeedImpressionBaseline>()) == 1)

    try sourceAdapter.resetPersonalization()
    let activityPolicy = try regressionEnvelope(.policy, id: SyncKind.activity.rawValue, in: sourceContext)
    let baselinePolicy = try regressionEnvelope(.policy, id: SyncKind.impressionBaseline.rawValue, in: sourceContext)
    let newID = try #require(
        RecommendationOutcomeStore.record(
            [
                .init(videoID: "new-video", position: 0, features: RecommendationSyncFeatures.empty.features)
            ], in: sourceContext)["new-video"])
    let newEvent = try regressionEnvelope(.activity, id: newID.uuidString.lowercased(), in: sourceContext)

    try destinationAdapter.apply(activityPolicy)
    try destinationAdapter.apply(newEvent)
    #expect(try destinationContext.fetch(FetchDescriptor<RecommendationOutcomeEntry>()).map(\.eventID) == [newID])
    try destinationAdapter.apply(baselinePolicy)
    try destinationAdapter.apply(baselinePolicy)

    let reader = ModelContext(destination)
    let outcomes = try reader.fetch(FetchDescriptor<RecommendationOutcomeEntry>())
    #expect(outcomes.count == 1)
    #expect(outcomes.first?.eventID == newID)
    #expect(outcomes.first?.videoID == "new-video")
    #expect(try reader.fetchCount(FetchDescriptor<FeedImpressionBaseline>()) == 0)
    #expect(FeedImpressionStore.counts(in: reader)["new-video"] == 1)
    #expect(FeedImpressionStore.counts(in: reader)["legacy-video"] == nil)
}

@MainActor
@Test func restoredFavoritesStagesNewChildrenAndSuppressesOldChildrenInEitherDeliveryOrder() throws {
    let source = try makeTestContainer()
    let offline = try makeTestContainer()
    let destination = try makeTestContainer()
    let sourceContext = source.mainContext
    let offlineContext = offline.mainContext
    let destinationContext = destination.mainContext
    for context in [sourceContext, offlineContext, destinationContext] { context.autosaveEnabled = false }
    let destinationAdapter = SyncStoreAdapter(context: destinationContext)
    let parentID = PlaylistStore.favoritesPlaylistID.uuidString.lowercased()
    #expect(
        PlaylistStore.addToFavorites(
            PlaylistVideoSnapshot(videoID: "original-video", title: "Original"), in: sourceContext) == .added)
    let originalParent = try regressionEnvelope(.playlist, id: parentID, in: sourceContext)
    let originalChildID = LibrarySyncJournal.playlistVideoIdentity(
        playlistID: PlaylistStore.favoritesPlaylistID, videoID: "original-video")
    let originalChild = try regressionEnvelope(.playlistVideo, id: originalChildID, in: sourceContext)
    try destinationAdapter.apply(originalParent)
    try destinationAdapter.apply(originalChild)
    try SyncStoreAdapter(context: offlineContext).apply(originalParent)
    #expect(
        PlaylistStore.addToFavorites(
            PlaylistVideoSnapshot(videoID: "offline-video", title: "Offline addition"), in: offlineContext) == .added)
    let offlineChildID = LibrarySyncJournal.playlistVideoIdentity(
        playlistID: PlaylistStore.favoritesPlaylistID, videoID: "offline-video")
    let offlineChild = try regressionEnvelope(.playlistVideo, id: offlineChildID, in: offlineContext)

    let original = try #require(PlaylistStore.favoritesPlaylist(in: sourceContext))
    #expect(PlaylistStore.delete(original, in: sourceContext))
    let deletion = try regressionEnvelope(.playlist, id: parentID, in: sourceContext)
    try destinationAdapter.apply(deletion)
    try destinationAdapter.apply(offlineChild)
    #expect(try destinationContext.fetchCount(FetchDescriptor<Playlist>()) == 0)
    #expect(try destinationContext.fetchCount(FetchDescriptor<PlaylistVideo>()) == 0)

    #expect(
        PlaylistStore.addToFavorites(
            PlaylistVideoSnapshot(videoID: "new-video", title: "New favorite"), in: sourceContext) == .added)
    let restored = try #require(PlaylistStore.favoritesPlaylist(in: sourceContext))
    let incarnation = try #require(restored.syncIncarnation)
    let restoredParent = try regressionEnvelope(.playlist, id: parentID, in: sourceContext)
    let newChildID = LibrarySyncJournal.playlistVideoIdentity(
        playlistID: restored.id, videoID: "new-video", incarnation: incarnation)
    let newChild = try regressionEnvelope(.playlistVideo, id: newChildID, in: sourceContext)
    try destinationAdapter.apply(newChild)
    #expect(try destinationContext.fetchCount(FetchDescriptor<PlaylistVideo>()) == 0)
    try destinationAdapter.apply(restoredParent)

    // Delayed parent deletions and initial-incarnation children cannot affect the restored library.
    for envelope in [originalParent, originalChild, offlineChild, deletion, newChild] {
        try destinationAdapter.apply(envelope)
    }
    let reader = ModelContext(destination)
    let favorites = try #require(reader.fetch(FetchDescriptor<Playlist>()).first)
    #expect(favorites.syncIncarnation == incarnation)
    #expect(favorites.orderedVideos.map(\.videoID) == ["new-video"])
    #expect(try reader.fetchCount(FetchDescriptor<PlaylistVideo>()) == 1)
    #expect(try destinationAdapter.state(kind: .playlistVideo, entityID: offlineChildID)?.isMaterialized == false)
    #expect(try destinationAdapter.state(kind: .playlistVideo, entityID: newChildID)?.isMaterialized == true)
}

@MainActor
private func regressionEnvelope(_ kind: SyncKind, id: String, in context: ModelContext) throws -> SyncEnvelope {
    let state = try #require(try SyncStoreAdapter(context: context).state(kind: kind, entityID: id))
    return try SyncPayload.decode(SyncEnvelope.self, from: state.envelopeData)
}
