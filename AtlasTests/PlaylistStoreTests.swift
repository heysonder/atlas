import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func playlistNamesUseOneCaseInsensitivePersistenceIdentity() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    #expect(PlaylistStore.createPlaylist(named: "Watch Later", in: context) != nil)
    #expect(PlaylistStore.createPlaylist(named: " watch later ", in: context) == nil)

    context.insert(Playlist(name: "WATCH LATER"))
    do {
        _ = try BackupStore.export(from: context)
        Issue.record("Expected duplicate playlist names to block export")
    } catch let error as BackupExportError {
        guard case .duplicateStoredValue(let field) = error else {
            Issue.record("Unexpected export error: \(error)")
            return
        }
        #expect(field.hasPrefix("playlists["))
        #expect(field.hasSuffix("].name"))
    }
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
