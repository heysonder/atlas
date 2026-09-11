import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func localPlaylistCreationRejectsAmbiguousNamesWithoutCollapsingSyncedIdentities() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    #expect(PlaylistStore.createPlaylist(named: "Watch Later", in: context) != nil)
    #expect(PlaylistStore.createPlaylist(named: " watch later ", in: context) == nil)

    context.insert(Playlist(name: "WATCH LATER"))
    // Independent synced UUIDs may share a display name and remain exportable.
    _ = try BackupStore.export(from: context)
    #expect(PlaylistStore.playlist(named: "Watch Later", in: context) == nil)
}

@MainActor
@Test func savedPlaylistMutationRollsBackWhenTheTransactionFails() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let playlist = Playlist(name: "Keep")
    context.insert(playlist)
    try context.save()

    let committed = PlaylistStore.performSavedMutation(in: context) {
        let video = PlaylistVideo(videoID: "video", title: "Transient")
        video.playlist = playlist
        context.insert(video)
        throw ForcedPersistenceFailure()
    }

    #expect(!committed)
    #expect(try context.fetch(FetchDescriptor<PlaylistVideo>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<Playlist>()).count == 1)
}

@MainActor
@Test func playlistStoreDedupesVideosByID() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let playlist = Playlist(name: "Watch Later")
    context.insert(playlist)
    let video = PlaylistVideoSnapshot(
        videoID: "v1",
        title: "One",
        uploader: "Creator",
        thumbnailURL: "thumb",
        duration: 42)

    #expect(PlaylistStore.add(video, to: playlist, in: context) == .added)
    #expect(PlaylistStore.add(video, to: playlist, in: context) == .duplicate)
    #expect(playlist.videos.count == 1)
    #expect(playlist.videos.first?.title == "One")
}

@MainActor
@Test func playlistStoreFindsOrCreatesFavoritesAndDedupesAdds() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let request = PlayRequest(
        videoID: "v1",
        title: "One",
        uploader: "Creator",
        thumbnail: "thumb")
    let snapshot = PlaylistVideoSnapshot(request: request)

    #expect(!PlaylistStore.isFavorite(videoID: "v1", in: context))
    #expect(PlaylistStore.addToFavorites(snapshot, in: context) == .added)
    #expect(PlaylistStore.addToFavorites(snapshot, in: context) == .duplicate)
    #expect(PlaylistStore.isFavorite(videoID: "v1", in: context))

    let favorites = try #require(PlaylistStore.playlist(named: "favorites", in: context))
    #expect(favorites.name == PlaylistStore.favoritesPlaylistName)
    #expect(favorites.videos.count == 1)
    #expect(favorites.videos.first?.videoID == "v1")
}

@MainActor
@Test func playlistStoreRemovesFavoritesByVideoID() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let snapshot = PlaylistVideoSnapshot(videoID: "v1", title: "One")

    #expect(PlaylistStore.removeFromFavorites(videoID: "v1", in: context) == .missing)
    #expect(PlaylistStore.addToFavorites(snapshot, in: context) == .added)
    #expect(PlaylistStore.removeFromFavorites(videoID: "v1", in: context) == .removed)
    #expect(!PlaylistStore.isFavorite(videoID: "v1", in: context))
    #expect(PlaylistStore.removeFromFavorites(videoID: "v1", in: context) == .missing)
}

@MainActor
@Test func rejectedFavoriteDoesNotLeaveAnEmptyPlaylist() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let invalidSnapshot = PlaylistVideoSnapshot(videoID: "", title: "Invalid")

    #expect(PlaylistStore.addToFavorites(invalidSnapshot, in: context) == .missing)
    #expect(PlaylistStore.favoritesPlaylist(in: context) == nil)
    #expect(try context.fetch(FetchDescriptor<Playlist>()).isEmpty)
}

@MainActor
@Test func createAndAddRejectsDuplicateNamesWithoutChangingExistingPlaylist() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let existing = try #require(PlaylistStore.createPlaylist(named: "Watch Later", in: context))
    let snapshot = PlaylistVideoSnapshot(videoID: "video", title: "Video")

    #expect(
        PlaylistStore.createPlaylist(
            named: " watch later ", adding: snapshot, in: context) == .missing)
    #expect(existing.videos.isEmpty)
    #expect(try context.fetch(FetchDescriptor<Playlist>()).count == 1)
    #expect(try context.fetch(FetchDescriptor<PlaylistVideo>()).isEmpty)
}

@MainActor
@Test func createAndAddRollsBackNewPlaylistWhenVideoIsRejected() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let invalid = PlaylistVideoSnapshot(videoID: "", title: "Invalid")

    #expect(
        PlaylistStore.createPlaylist(
            named: "Must Not Remain", adding: invalid, in: context) == .missing)
    #expect(try context.fetch(FetchDescriptor<Playlist>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<PlaylistVideo>()).isEmpty)
}

private struct ForcedPersistenceFailure: Error {}

@MainActor
@Test func favoritesReadsNeverMutateALegacyRowAndMutationsAdoptIt() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let legacy = Playlist(name: "Favorites")
    let legacyID = legacy.id
    context.insert(legacy)
    let video = PlaylistVideo(videoID: "v1", title: "One")
    video.playlist = legacy
    context.insert(video)
    try context.save()

    // Reads (the player's favorite state, a bound detail view) leave the row alone.
    #expect(PlaylistStore.isFavorite(videoID: "v1", in: context))
    #expect(PlaylistStore.favoritesPlaylist(in: context) === legacy)
    #expect(!legacy.isDeleted)
    #expect(try context.fetchCount(FetchDescriptor<Playlist>()) == 1)

    // A mutation folds it into the canonical Favorites first.
    #expect(PlaylistStore.addToFavorites(.init(videoID: "v2", title: "Two"), in: context) == .added)
    let canonical = try #require(PlaylistStore.favoritesPlaylist(in: context))
    #expect(canonical.id == PlaylistStore.favoritesPlaylistID)
    #expect(canonical.videos.map(\.videoID).sorted() == ["v1", "v2"])
    #expect(canonical.legacyIDs?.contains(legacyID) == true)
    #expect(try context.fetchCount(FetchDescriptor<Playlist>()) == 1)
    #expect(PlaylistStore.adoptLegacyFavoritesIfNeeded(in: context))
}
