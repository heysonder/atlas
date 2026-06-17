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
@Test func instanceStoreKeepsAndMirrorsValidDefaultsValue() throws {
    let defaults = makeTestDefaults()
    let secureStore = MemoryInstanceSecureStore()
    defaults.set("pipedapi.cmf.sh/", forKey: InstanceStore.defaultsKey)

    let store = InstanceStore(defaults: defaults, secureStore: secureStore)

    #expect(store.load() == "https://pipedapi.cmf.sh")
    #expect(defaults.string(forKey: InstanceStore.defaultsKey) == "https://pipedapi.cmf.sh")
    #expect(secureStore.value == "https://pipedapi.cmf.sh")
}

@MainActor
@Test func instanceStoreRestoresDefaultsFromSecureStore() throws {
    let defaults = makeTestDefaults()
    let secureStore = MemoryInstanceSecureStore(value: "https://piped.example")
    let store = InstanceStore(defaults: defaults, secureStore: secureStore)

    #expect(store.load() == "https://piped.example")
    #expect(defaults.string(forKey: InstanceStore.defaultsKey) == "https://piped.example")
    #expect(secureStore.value == "https://piped.example")
}

@MainActor
@Test func instanceStoreAllowsHTTPForLocalAndPrivateHosts() throws {
    let allowed = [
        "http://localhost:8080",
        "http://0.0.0.0:8080",
        "http://127.0.0.1:8080",
        "http://192.168.1.24:8080",
        "http://10.0.0.5",
        "http://172.20.10.2",
        "http://atlas-lan:8080",
        "http://[::1]:8080",
        "http://[fd00::1]:8080"
    ]

    for rawURL in allowed {
        #expect(InstanceStore.isValidInstanceURL(rawURL))
    }
}

@MainActor
@Test func instanceStoreRejectsHTTPForPublicDomains() throws {
    #expect(!InstanceStore.isValidInstanceURL("http://piped.example"))
    #expect(!InstanceStore.isValidInstanceURL("http://example.com"))
}

@MainActor
@Test func instanceStoreClearsInvalidSavedValues() throws {
    let defaults = makeTestDefaults()
    let secureStore = MemoryInstanceSecureStore(value: "not a url")
    defaults.set("ftp://piped.example", forKey: InstanceStore.defaultsKey)
    let store = InstanceStore(defaults: defaults, secureStore: secureStore)

    #expect(store.load().isEmpty)
    #expect(defaults.string(forKey: InstanceStore.defaultsKey) == nil)
    #expect(secureStore.value == nil)
}

@MainActor
private func makeTestContainer() throws -> ModelContainer {
    let schema = AtlasModelSchema.schema
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

private func makeTestDefaults() -> UserDefaults {
    let suiteName = "atlas.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private final class MemoryInstanceSecureStore: InstanceSecureStoring {
    var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func loadInstanceURL() -> String? {
        value
    }

    func saveInstanceURL(_ value: String) {
        self.value = value
    }

    func clearInstanceURL() {
        value = nil
    }
}
