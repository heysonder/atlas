import Foundation
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func successfulLibraryMutationAndTombstonePersistWithoutAutosave() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    context.autosaveEnabled = false
    #expect(
        SubscriptionStore.setSubscribed(
            true, channelID: "channel", name: "Creator", avatarURL: nil, in: context))

    let reader = ModelContext(container)
    #expect(try reader.fetchCount(FetchDescriptor<SubscribedChannel>()) == 1)
    let insertedState = try #require(
        try SyncStoreAdapter(context: reader).state(kind: .subscription, entityID: "channel"))
    #expect(try !SyncPayload.decode(SyncEnvelope.self, from: insertedState.envelopeData).isTombstone)
    #expect(insertedState.localRevision > insertedState.acknowledgedRevision)

    #expect(
        SubscriptionStore.setSubscribed(
            false, channelID: "channel", name: nil, avatarURL: nil, in: context))
    let afterRemoval = ModelContext(container)
    #expect(try afterRemoval.fetchCount(FetchDescriptor<SubscribedChannel>()) == 0)
    let tombstone = try #require(
        try SyncStoreAdapter(context: afterRemoval).state(kind: .subscription, entityID: "channel"))
    #expect(try SyncPayload.decode(SyncEnvelope.self, from: tombstone.envelopeData).isTombstone)
}

@MainActor
@Test func recentSearchProjectionDoesNotDeleteRetainedSignals() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    for index in 0..<22 {
        #expect(
            SearchHistoryStore.record(
                "query \(index)", in: context, now: Date(timeIntervalSince1970: Double(index))) != nil)
    }
    SearchHistoryStore.prune(in: context)
    let retained = try context.fetch(FetchDescriptor<SearchEntry>())
    let recent = SearchHistoryStore.recent(retained)
    #expect(retained.count == 22)
    #expect(recent.count == 15)
    #expect(recent.first?.query == "query 21")
    #expect(recent.last?.query == "query 7")
    #expect(try context.fetchCount(FetchDescriptor<SyncRecordState>()) >= 22)
    #expect(SearchHistoryStore.clear(recent, in: context))
    #expect(try context.fetchCount(FetchDescriptor<SearchEntry>()) == 0)
    #expect(try SyncStoreAdapter(context: context).generation(for: .search) != "initial")
}

@MainActor
@Test func laterPlaybackSessionCanReplaceResumeWithAnEarlierPosition() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let earlier = try #require(PlaybackHistoryStore.beginSession(videoID: "video", in: context))
    #expect(
        PlaybackHistoryStore.record(
            videoID: "video", title: "Video", uploader: nil, thumbnailURL: nil, session: earlier, in: context))
    #expect(
        PlaybackHistoryStore.savePosition(
            2_400, videoID: "video", duration: 5_000, session: earlier, in: context))
    let later = try #require(PlaybackHistoryStore.beginSession(videoID: "video", in: context))
    #expect(
        PlaybackHistoryStore.record(
            videoID: "video", title: "Video", uploader: nil, thumbnailURL: nil, session: later, in: context))
    #expect(
        PlaybackHistoryStore.savePosition(
            120, videoID: "video", duration: 4_000, session: later, in: context))
    let entry = try #require(context.fetch(FetchDescriptor<HistoryEntry>()).first)
    #expect(entry.positionSeconds == 120)
    #expect(entry.durationSeconds == 4_000)
    #expect(entry.playbackSessionID == later.id)
    #expect(entry.playbackSequence == 1)
}

@MainActor
@Test func clearAndRemovalFenceExistingPlaybackSessions() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let oldSession = try #require(PlaybackHistoryStore.beginSession(videoID: "video", in: context))
    #expect(
        PlaybackHistoryStore.record(
            videoID: "video", title: "Video", uploader: nil, thumbnailURL: nil,
            session: oldSession, in: context))
    #expect(PlaybackHistoryStore.clear(in: context))
    #expect(
        !PlaybackHistoryStore.record(
            videoID: "video", title: "Video", uploader: nil, thumbnailURL: nil,
            session: oldSession, in: context))
    #expect(
        !PlaybackHistoryStore.savePosition(
            45, videoID: "video", duration: 100, session: oldSession, in: context))

    let newSession = try #require(PlaybackHistoryStore.beginSession(videoID: "video", in: context))
    #expect(
        PlaybackHistoryStore.record(
            videoID: "video", title: "Video", uploader: nil, thumbnailURL: nil,
            session: newSession, in: context))
    let entry = try #require(context.fetch(FetchDescriptor<HistoryEntry>()).first)
    #expect(PlaybackHistoryStore.remove([entry], in: context))
    #expect(
        !PlaybackHistoryStore.record(
            videoID: "video", title: "Video", uploader: nil, thumbnailURL: nil,
            session: newSession, in: context))
    #expect(try context.fetchCount(FetchDescriptor<HistoryEntry>()) == 0)
}

@MainActor
@Test func legacyFavoritesAdoptionUnionsMembershipAndPreservesShortcutAliases() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let firstID = UUID()
    let secondID = UUID()
    let first = Playlist(id: firstID, name: "Favorites")
    let second = Playlist(id: secondID, name: "FAVORITES")
    context.insert(first)
    context.insert(second)
    for (id, playlist) in [("z", first), ("a", second), ("z", second)] {
        let video = PlaylistVideo(videoID: id, title: id, addedAt: Date(timeIntervalSince1970: 100))
        video.playlist = playlist
        context.insert(video)
    }
    try context.save()

    // Reads answer with the legacy row untouched; launch (or a mutation) adopts it.
    let readBeforeAdoption = PlaylistStore.favoritesPlaylist(in: context)
    #expect(readBeforeAdoption === first || readBeforeAdoption === second)
    #expect(try context.fetchCount(FetchDescriptor<Playlist>()) == 2)
    #expect(PlaylistStore.adoptLegacyFavoritesIfNeeded(in: context))
    let favorites = try #require(PlaylistStore.favoritesPlaylist(in: context))
    #expect(favorites.id == PlaylistStore.favoritesPlaylistID)
    #expect(favorites.systemKind == PlaylistStore.favoritesSystemKind)
    #expect(favorites.orderedVideos.map(\.videoID) == ["a", "z"])
    #expect(PlaylistStore.playlist(id: firstID, in: context)?.id == favorites.id)
    #expect(PlaylistStore.playlist(id: secondID, in: context)?.id == favorites.id)
    #expect(try context.fetchCount(FetchDescriptor<Playlist>()) == 1)
}

@MainActor
@Test func syncedSameNamePlaylistsRequireUUIDSelection() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let first = Playlist(name: "Shared name")
    let second = Playlist(name: "SHARED NAME")
    context.insert(first)
    context.insert(second)
    try context.save()
    #expect(PlaylistStore.playlist(named: "Shared name", in: context) == nil)
    #expect(
        PlaylistStore.add(
            PlaylistVideoSnapshot(videoID: "video", title: "Video"),
            toPlaylistNamed: "Shared name", in: context) == .missing)
    #expect(first.videos.isEmpty && second.videos.isEmpty)
    #expect(PlaylistStore.displayName(for: first, among: [first, second]) != first.name)
    #expect(PlaylistStore.playlist(id: first.id, in: context)?.id == first.id)
}

@MainActor
@Test func freshSearchesMergePerInstallationCountsWithoutReplayInflation() throws {
    let first = try makeTestContainer()
    let second = try makeTestContainer()
    #expect(SearchHistoryStore.record("shared query", in: first.mainContext) != nil)
    #expect(SearchHistoryStore.record("shared query", in: second.mainContext) != nil)
    let firstAdapter = SyncStoreAdapter(context: first.mainContext)
    let secondAdapter = SyncStoreAdapter(context: second.mainContext)
    let firstEnvelope = try libraryEnvelope(.search, id: "shared query", in: first.mainContext)
    let secondEnvelope = try libraryEnvelope(.search, id: "shared query", in: second.mainContext)
    try firstAdapter.apply(secondEnvelope)
    try secondAdapter.apply(firstEnvelope)
    try firstAdapter.apply(secondEnvelope)
    try secondAdapter.apply(firstEnvelope)
    #expect(try first.mainContext.fetch(FetchDescriptor<SearchEntry>()).first?.count == 2)
    #expect(try second.mainContext.fetch(FetchDescriptor<SearchEntry>()).first?.count == 2)
    #expect(SearchHistoryStore.record("shared query", in: first.mainContext)?.count == 3)
    try secondAdapter.apply(libraryEnvelope(.search, id: "shared query", in: first.mainContext))
    #expect(try second.mainContext.fetch(FetchDescriptor<SearchEntry>()).first?.count == 3)
}

@MainActor
@Test func restoredFavoritesRejectsOldOfflineMembership() throws {
    let local = try makeTestContainer()
    let offline = try makeTestContainer()
    let localContext = local.mainContext
    let offlineContext = offline.mainContext
    #expect(
        PlaylistStore.addToFavorites(
            PlaylistVideoSnapshot(videoID: "original", title: "Original"), in: localContext) == .added)
    let parentID = PlaylistStore.favoritesPlaylistID.uuidString.lowercased()
    let offlineAdapter = SyncStoreAdapter(context: offlineContext)
    try offlineAdapter.apply(libraryEnvelope(.playlist, id: parentID, in: localContext))
    #expect(
        PlaylistStore.addToFavorites(
            PlaylistVideoSnapshot(videoID: "stale", title: "Offline addition"), in: offlineContext) == .added)
    let oldChildIdentity = LibrarySyncJournal.playlistVideoIdentity(
        playlistID: PlaylistStore.favoritesPlaylistID, videoID: "stale")
    let oldChild = try libraryEnvelope(.playlistVideo, id: oldChildIdentity, in: offlineContext)

    let original = try #require(PlaylistStore.favoritesPlaylist(in: localContext))
    #expect(PlaylistStore.delete(original, in: localContext))
    #expect(
        PlaylistStore.addToFavorites(
            PlaylistVideoSnapshot(videoID: "new", title: "New favorite"), in: localContext) == .added)
    let restored = try #require(PlaylistStore.favoritesPlaylist(in: localContext))
    #expect(restored.syncIncarnation != nil)
    try SyncStoreAdapter(context: localContext).apply(oldChild)
    #expect(restored.orderedVideos.map(\.videoID) == ["new"])
}

@MainActor
private func libraryEnvelope(_ kind: SyncKind, id: String, in context: ModelContext) throws -> SyncEnvelope {
    let state = try #require(try SyncStoreAdapter(context: context).state(kind: kind, entityID: id))
    return try SyncPayload.decode(SyncEnvelope.self, from: state.envelopeData)
}

@MainActor
@Test func playlistMembershipIdentityPreservesAllowedIdentifierSeparators() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let playlist = try #require(PlaylistStore.createPlaylist(named: "Imported IDs", in: context))
    #expect(
        PlaylistStore.add(
            PlaylistVideoSnapshot(videoID: "provider:video", title: "Video"), to: playlist, in: context) == .added)
    let identity = LibrarySyncJournal.playlistVideoIdentity(playlistID: playlist.id, videoID: "provider:video")
    let addition = try libraryEnvelope(.playlistVideo, id: identity, in: context)
    #expect(!addition.isTombstone)
    #expect(PlaylistStore.removeVideoID("provider:video", from: playlist, in: context) == .removed)
    #expect(try libraryEnvelope(.playlistVideo, id: identity, in: context).isTombstone)
    #expect(playlist.videos.isEmpty)
}

@MainActor
@Test func removingMalformedLegacyRowsDoesNotCreateUnsyncableJournalRecords() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let malformedID = String(repeating: "x", count: 2_049)
    let history = HistoryEntry(videoID: malformedID, title: "Legacy")
    let search = SearchEntry(query: malformedID)
    let playlist = Playlist(name: "Legacy")
    let video = PlaylistVideo(videoID: malformedID, title: "Legacy")
    context.insert(SubscribedChannel(channelID: malformedID, name: "Legacy"))
    context.insert(Feedback(videoID: malformedID, signal: 1, title: "Legacy"))
    context.insert(history)
    context.insert(search)
    context.insert(playlist)
    video.playlist = playlist
    context.insert(video)
    try context.save()

    #expect(
        SubscriptionStore.setSubscribed(
            false, channelID: malformedID, name: nil, avatarURL: nil, in: context))
    #expect(
        FeedbackStore.set(
            0, videoID: malformedID, title: "", uploader: nil, category: nil, tags: nil, in: context))
    #expect(PlaybackHistoryStore.remove([history], in: context))
    #expect(SearchHistoryStore.delete(search, in: context))
    #expect(PlaylistStore.removeVideoID(malformedID, from: playlist, in: context) == .removed)

    let reader = ModelContext(container)
    #expect(try reader.fetchCount(FetchDescriptor<SubscribedChannel>()) == 0)
    #expect(try reader.fetchCount(FetchDescriptor<Feedback>()) == 0)
    #expect(try reader.fetchCount(FetchDescriptor<HistoryEntry>()) == 0)
    #expect(try reader.fetchCount(FetchDescriptor<SearchEntry>()) == 0)
    #expect(try reader.fetchCount(FetchDescriptor<PlaylistVideo>()) == 0)
    #expect(try reader.fetchCount(FetchDescriptor<SyncRecordState>()) == 0)
}

@MainActor
@Test func rejectedPlaylistMutationPreservesUnrelatedPendingChanges() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    _ = try #require(PlaylistStore.createPlaylist(named: "Existing", in: context))
    context.insert(HistoryEntry(videoID: "pending", title: "Pending history"))
    #expect(PlaylistStore.createPlaylist(named: "EXISTING", in: context) == nil)
    #expect(
        PlaylistStore.createPlaylist(
            named: "existing", adding: PlaylistVideoSnapshot(videoID: "video", title: "Video"),
            in: context) == .missing)
    #expect(try context.fetchCount(FetchDescriptor<HistoryEntry>()) == 1)
    #expect(context.hasChanges)
}
