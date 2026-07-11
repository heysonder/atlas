import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func playlistCreationRejectsOversizedNamesWithoutInsertingRows() throws {
    let container = try makeViewPersistenceTestContainer()
    let modelContext = container.mainContext
    let oversizedName = String(
        repeating: "x",
        count: PersistedMetadataPolicy.maximumHumanTextBytes + 1)

    #expect(PlaylistStore.createPlaylist(named: oversizedName, in: modelContext) == nil)
    #expect(try modelContext.fetch(FetchDescriptor<Playlist>()).isEmpty)
}

@MainActor
@Test func playlistCreationRespectsTheLivePlaylistCapacity() throws {
    let container = try makeViewPersistenceTestContainer()
    let modelContext = container.mainContext
    for index in 0..<PersistedMetadataPolicy.maximumPlaylists {
        modelContext.insert(Playlist(name: "Playlist \(index)"))
    }

    #expect(PlaylistStore.createPlaylist(named: "One Too Many", in: modelContext) == nil)
    #expect(
        try modelContext.fetchCount(FetchDescriptor<Playlist>())
            == PersistedMetadataPolicy.maximumPlaylists)
}

@MainActor
@Test func intentPlaylistCreationIsValidatedAndAtomic() throws {
    let container = try makeViewPersistenceTestContainer()
    let modelContext = container.mainContext
    let previousContainer = IntentDataStore.injectedContainer
    IntentDataStore.injectedContainer = container
    defer { IntentDataStore.injectedContainer = previousContainer }

    let validVideo = VideoEntity(
        id: "video-id",
        title: "Video",
        uploader: "Creator",
        thumbnail: nil)
    let oversizedName = String(
        repeating: "x",
        count: PersistedMetadataPolicy.maximumHumanTextBytes + 1)
    #expect(
        intentAddResultIsMissing(
            IntentDataStore.addVideo(
                validVideo,
                to: .toCreate(named: oversizedName))))

    let invalidVideo = VideoEntity(
        id: "",
        title: "Invalid",
        uploader: nil,
        thumbnail: nil)
    #expect(
        intentAddResultIsMissing(
            IntentDataStore.addVideo(
                invalidVideo,
                to: .toCreate(named: "Must Roll Back"))))
    #expect(try modelContext.fetch(FetchDescriptor<Playlist>()).isEmpty)
    #expect(try modelContext.fetch(FetchDescriptor<PlaylistVideo>()).isEmpty)

    let result = IntentDataStore.addVideo(
        validVideo,
        to: .toCreate(named: "Watch Later"))
    guard case .added = result else {
        Issue.record("Expected the validated intent mutation to add the video.")
        return
    }
    #expect(try modelContext.fetchCount(FetchDescriptor<Playlist>()) == 1)
    #expect(try modelContext.fetchCount(FetchDescriptor<PlaylistVideo>()) == 1)
}

@MainActor
@Test func historyAndPlaylistDeletionUseStoreBoundaries() throws {
    let container = try makeViewPersistenceTestContainer()
    let modelContext = container.mainContext
    let history = HistoryEntry(videoID: "history", title: "History")
    modelContext.insert(history)
    let playlist = try #require(
        PlaylistStore.createPlaylist(named: "Playlist", in: modelContext))
    #expect(
        PlaylistStore.add(
            PlaylistVideoSnapshot(videoID: "saved", title: "Saved"),
            to: playlist,
            in: modelContext) == .added)

    PlaybackHistoryStore.remove([history], in: modelContext)
    #expect(
        PlaylistStore.removeVideoID(
            "saved",
            from: playlist,
            in: modelContext) == .removed)
    PlaylistStore.delete(playlist, in: modelContext)

    #expect(try modelContext.fetch(FetchDescriptor<HistoryEntry>()).isEmpty)
    #expect(try modelContext.fetch(FetchDescriptor<PlaylistVideo>()).isEmpty)
    #expect(try modelContext.fetch(FetchDescriptor<Playlist>()).isEmpty)
}

private func intentAddResultIsMissing(_ result: IntentDataStore.AddResult) -> Bool {
    if case .missing = result { return true }
    return false
}

@MainActor
private func makeViewPersistenceTestContainer() throws -> ModelContainer {
    let schema = AtlasModelSchema.schema
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}
