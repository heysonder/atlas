import Foundation
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func cloudSyncHistoricalSchemaKeepsOriginalEntityNamesAndVersion() {
    let unversioned = Schema(AtlasSchemaV1.models)
    let versioned = Schema(versionedSchema: AtlasSchemaV1.self)
    let expected: Set<String> = [
        "SubscribedChannel", "HistoryEntry", "Playlist", "PlaylistVideo",
        "DownloadedVideo", "Feedback", "SearchEntry", "VideoSignalCacheEntry",
        "RecommendationProfileSnapshot", "FeedImpressionEntry", "RecommendationOutcomeEntry",
    ]

    #expect(unversioned.version == AtlasSchemaV1.versionIdentifier)
    #expect(Set(unversioned.entities.map(\.name)) == expected)
    #expect(Set(versioned.entities.map(\.name)) == expected)
    #expect(Schema.entityName(for: AtlasSchemaV1.HistoryEntry.self) == Schema.entityName(for: HistoryEntry.self))
    #expect(Schema.entityName(for: AtlasSchemaV1.Playlist.self) == Schema.entityName(for: Playlist.self))
}

@MainActor
@Test func cloudSyncMigratesOriginalUnversionedDiskStoreWithoutLosingLibrary() throws {
    let fixture = try CloudSyncMigrationFixture()
    defer { fixture.remove() }
    try fixture.writeOriginalStore()

    let container = try fixture.openCurrentStore()
    let context = ModelContext(container)
    context.autosaveEnabled = false

    let subscription = try #require(context.fetch(FetchDescriptor<SubscribedChannel>()).first)
    #expect(subscription.channelID == "channel-1")
    #expect(subscription.name == "A subscribed creator")
    #expect(subscription.avatarURL == "https://example.com/avatar.jpg")
    #expect(subscription.subscribedAt == fixture.date)

    let history = try #require(context.fetch(FetchDescriptor<HistoryEntry>()).first)
    #expect(history.videoID == "watched-1")
    #expect(history.positionSeconds == 125)
    #expect(history.durationSeconds == 900)
    #expect(history.watchedAt == fixture.date)
    #expect(history.playbackSessionID == nil)
    #expect(history.playbackSessionStartedAt == nil)
    #expect(history.playbackSequence == 0)

    let playlist = try #require(context.fetch(FetchDescriptor<Playlist>()).first)
    #expect(playlist.id == fixture.playlistID)
    #expect(playlist.name == "Favorites")
    #expect(playlist.createdAt == fixture.date)
    #expect(playlist.systemKind == nil)
    #expect(playlist.legacyIDs == nil)
    #expect(playlist.videos.count == 1)
    let video = try #require(playlist.videos.first)
    #expect(video.videoID == "saved-1")
    #expect(video.title == "Saved title")
    #expect(video.duration == 720)
    #expect(video.playlist?.id == fixture.playlistID)
    #expect(try context.fetchCount(FetchDescriptor<PlaylistVideo>()) == 1)

    let download = try #require(context.fetch(FetchDescriptor<DownloadedVideo>()).first)
    #expect(download.fileName == "download-1.mp4")
    #expect(download.thumbnailFileName == "download-1.jpg")
    #expect(download.captionFileName == "download-1.vtt")
    #expect(download.captionMimeType == "text/vtt")
    #expect(download.captionLanguageCode == "en")
    #expect(download.captionName == "English")
    #expect(download.qualityLabel == "1080p")
    #expect(download.byteCount == 12_345)

    let feedback = try #require(context.fetch(FetchDescriptor<Feedback>()).first)
    #expect(feedback.signal == -1)
    #expect(feedback.category == "Education")
    #expect(feedback.tags == ["swift", "ios"])
    let search = try #require(context.fetch(FetchDescriptor<SearchEntry>()).first)
    #expect(search.query == "swiftui")
    #expect(search.displayQuery == "SwiftUI")
    #expect(search.count == 7)
    #expect(search.lastSearchedAt == fixture.date)

    let signals = try #require(context.fetch(FetchDescriptor<VideoSignalCacheEntry>()).first)
    #expect(signals.channelID == "channel-1")
    #expect(signals.tags == ["swift"])
    #expect(signals.topicKey == "programming")
    let profile = try #require(context.fetch(FetchDescriptor<RecommendationProfileSnapshot>()).first)
    #expect(profile.signature == "original-profile")
    #expect(profile.relatedSeedIDs == ["watched-1"])
    #expect(profile.channelAffinityKeys == ["channel-1"])
    #expect(profile.channelAffinityValues == [0.75])
    let impression = try #require(context.fetch(FetchDescriptor<FeedImpressionEntry>()).first)
    #expect(impression.count == 3)
    #expect(impression.lastShownAt == fixture.date)

    let outcomes = try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>())
    #expect(outcomes.count == 2)
    #expect(outcomes.allSatisfy { $0.eventID == nil })
    #expect(outcomes.allSatisfy { !$0.contributesToImpressions })
    #expect(outcomes.allSatisfy { $0.featureSchemaVersion == 1 })
    let tapped = try #require(outcomes.first { $0.videoID == "shown-1" })
    #expect(tapped.tapped)
    #expect(tapped.tappedAt == fixture.date.addingTimeInterval(20))
    #expect(tapped.topicSimilarity == 0.4)
    #expect(tapped.channelAffinity == 0.7)
    #expect(tapped.fromSubscription)

    // The historical relationship retains its cascade rule after migration.
    context.delete(playlist)
    try context.save()
    #expect(try context.fetchCount(FetchDescriptor<PlaylistVideo>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<DownloadedVideo>()) == 1)
}

@MainActor
@Test func cloudSyncLegacyActivityBackfillAssignsDistinctStableIDsOnce() throws {
    let fixture = try CloudSyncMigrationFixture()
    defer { fixture.remove() }
    try fixture.writeOriginalStore()

    let firstIDs: (outcomes: Set<UUID>, baselines: Set<UUID>) = try autoreleasepool {
        let context = ModelContext(try fixture.openCurrentStore())
        context.autosaveEnabled = false
        _ = try RecommendationSyncBridge.prepare(in: context)
        try context.save()

        let outcomes = try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>())
        let ids = Set(outcomes.compactMap(\.eventID))
        #expect(ids.count == 2)
        #expect(outcomes.allSatisfy { !$0.contributesToImpressions })
        let baselines = try context.fetch(FetchDescriptor<FeedImpressionBaseline>())
        let aggregate = try #require(baselines.first { $0.count > 0 })
        let tapReset = try #require(baselines.first { $0.count == 0 })
        let tapped = try #require(outcomes.first { $0.tapped })
        #expect(baselines.count == 2)
        #expect(aggregate.count == 3)
        #expect(aggregate.videoID == "shown-1")
        #expect(tapReset.id == tapped.eventID)
        #expect(tapReset.videoID == tapped.videoID)
        #expect(tapReset.lastShownAt == tapped.tappedAt)
        return (ids, Set(baselines.map(\.id)))
    }

    try autoreleasepool {
        let context = ModelContext(try fixture.openCurrentStore())
        context.autosaveEnabled = false
        _ = try RecommendationSyncBridge.prepare(in: context)
        try context.save()

        let outcomes = try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>())
        #expect(Set(outcomes.compactMap(\.eventID)) == firstIDs.outcomes)
        let baselines = try context.fetch(FetchDescriptor<FeedImpressionBaseline>())
        #expect(Set(baselines.map(\.id)) == firstIDs.baselines)
        #expect(baselines.count == 2)
        #expect(baselines.filter { $0.count == 3 && $0.videoID == "shown-1" }.count == 1)
        #expect(baselines.filter { $0.count == 0 && $0.videoID == "shown-1" }.count == 1)
        #expect(try context.fetchCount(FetchDescriptor<RecommendationActivityState>()) == 1)
    }
}

/// This intentionally writes with the old *unversioned* constructor. A test that
/// writes V1 using the migration plan would miss upgrades from released builds.
@MainActor
private struct CloudSyncMigrationFixture {
    let directory: URL
    let storeURL: URL
    let date = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) - 3_600)
    let playlistID = UUID()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "atlas-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        storeURL = directory.appending(path: "default.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func openCurrentStore() throws -> ModelContainer {
        let schema = Schema(versionedSchema: AtlasSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        return try ModelContainer(
            for: schema, migrationPlan: AtlasSchemaMigrationPlan.self,
            configurations: [configuration])
    }

    func writeOriginalStore() throws {
        try autoreleasepool {
            let schema = Schema(AtlasSchemaV1.models)
            let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(
                AtlasSchemaV1.SubscribedChannel(
                    channelID: "channel-1", name: "A subscribed creator",
                    avatarURL: "https://example.com/avatar.jpg", subscribedAt: date))
            context.insert(
                AtlasSchemaV1.HistoryEntry(
                    videoID: "watched-1", title: "Watched title", uploader: "Creator",
                    watchedAt: date, positionSeconds: 125, durationSeconds: 900))
            let playlist = AtlasSchemaV1.Playlist(id: playlistID, name: "Favorites", createdAt: date)
            let video = AtlasSchemaV1.PlaylistVideo(
                videoID: "saved-1", title: "Saved title", uploader: "Creator",
                duration: 720, addedAt: date)
            context.insert(playlist)
            context.insert(video)
            playlist.videos.append(video)
            video.playlist = playlist
            context.insert(
                AtlasSchemaV1.DownloadedVideo(
                    videoID: "download-1", title: "Offline title", fileName: "download-1.mp4",
                    thumbnailFileName: "download-1.jpg", captionFileName: "download-1.vtt",
                    captionMimeType: "text/vtt", captionLanguageCode: "en", captionName: "English",
                    durationSeconds: 900, qualityLabel: "1080p", byteCount: 12_345, createdAt: date))
            context.insert(
                AtlasSchemaV1.Feedback(
                    videoID: "feedback-1", signal: -1, title: "Feedback title",
                    category: "Education", tags: ["swift", "ios"], createdAt: date))
            context.insert(
                AtlasSchemaV1.SearchEntry(
                    query: "swiftui", displayQuery: "SwiftUI", lastSearchedAt: date, count: 7))
            context.insert(
                AtlasSchemaV1.VideoSignalCacheEntry(
                    videoID: "signal-1", title: "Signal title", channelID: "channel-1",
                    category: "Education", tags: ["swift"], topicKey: "programming", updatedAt: date))
            context.insert(
                AtlasSchemaV1.RecommendationProfileSnapshot(
                    signature: "original-profile", relatedSeedIDs: ["watched-1"], explorationSeedIDs: [],
                    candidateSearchQueries: ["swiftui"], savedSeedIDs: ["saved-1"],
                    channelAffinityKeys: ["channel-1"], channelAffinityValues: [0.75], updatedAt: date))
            context.insert(AtlasSchemaV1.FeedImpressionEntry(videoID: "shown-1", count: 3, lastShownAt: date))
            let first = AtlasSchemaV1.RecommendationOutcomeEntry(videoID: "shown-1", shownAt: date, position: 0)
            first.tapped = true
            first.tappedAt = date.addingTimeInterval(20)
            first.topicSimilarity = 0.4
            first.channelAffinity = 0.7
            first.fromSubscription = true
            context.insert(first)
            context.insert(AtlasSchemaV1.RecommendationOutcomeEntry(videoID: "shown-2", shownAt: date, position: 1))
            try context.save()
        }
    }
}
