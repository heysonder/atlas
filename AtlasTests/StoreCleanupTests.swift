import Foundation
import SwiftData
import Testing
import PipedKit
@testable import Atlas

@MainActor
@Test func atlasModelSchemaContainsIntentModels() throws {
    let modelNames = Set(AtlasModelSchema.modelTypes.map { String(describing: $0) })

    #expect(modelNames.contains("SubscribedChannel"))
    #expect(modelNames.contains("HistoryEntry"))
    #expect(modelNames.contains("Playlist"))
    #expect(modelNames.contains("PlaylistVideo"))
    #expect(modelNames.contains("DownloadedVideo"))
    #expect(modelNames.contains("Feedback"))
    #expect(modelNames.contains("SearchEntry"))
    #expect(modelNames.contains("VideoSignalCacheEntry"))
    #expect(modelNames.contains("RecommendationProfileSnapshot"))

    _ = try makeTestContainer()
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
@Test func playbackHistoryStoreIgnoresFinishedResumePositions() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    context.insert(HistoryEntry(videoID: "v1", title: "One",
                                positionSeconds: 95, durationSeconds: 100))

    #expect(PlaybackHistoryStore.savedPosition(for: "v1", in: context) == nil)

    PlaybackHistoryStore.savePosition(40, videoID: "v1", duration: 100, in: context)
    #expect(PlaybackHistoryStore.savedPosition(for: "v1", in: context) == 40)
}

@MainActor
@Test func subscriptionStoreTogglesChannelRows() throws {
    let container = try makeTestContainer()
    let context = container.mainContext

    #expect(!SubscriptionStore.isSubscribed("c1", in: context))
    SubscriptionStore.setSubscribed(true, channelID: "c1",
                                    name: "Creator", avatarURL: "avatar", in: context)
    #expect(SubscriptionStore.isSubscribed("c1", in: context))
    SubscriptionStore.setSubscribed(false, channelID: "c1",
                                    name: nil, avatarURL: nil, in: context)
    #expect(!SubscriptionStore.isSubscribed("c1", in: context))
}

@MainActor
@Test func commentDisplayPrecomputesPlainTextAndTimestamps() throws {
    let json = """
    {"commentText":"Intro <a href=\\"/watch?v=x&t=83\\">1:23</a><br>Deep &amp; clean 1:02:03"}
    """.data(using: .utf8)!
    let comment = try JSONDecoder().decode(PipedKit.Comment.self, from: json)
    let display = CommentDisplay(comment)

    #expect(!display.plainText.contains("<a"))
    #expect(display.plainText.contains("Deep & clean"))
    #expect(display.timestamps.map(\.seconds) == [83, 3723])
    #expect(display.timestamps.map(\.label) == ["1:23", "1:02:03"])
}

@MainActor
private func makeTestContainer() throws -> ModelContainer {
    let schema = AtlasModelSchema.schema
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}
