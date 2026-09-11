import Foundation
import SwiftData
import Testing

@testable import Atlas

// A store written by a build whose models predate the frozen AtlasSchemaV1 has a
// model version the staged migration plan does not know. Those installs must still
// open through an inferred lightweight migration instead of launching on temporary
// storage with the user's library hidden.

@MainActor
@Suite(.serialized)
struct ContainerRecoveryTests {
    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-container-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Atlas.store")
    }

    @Test func storeFromAnOlderModelVersionOpensWithItsDataIntact() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // An early app version: a subset of the V1 entities, so the version hash
        // matches neither schema in the migration plan.
        try autoreleasepool {
            let older = Schema([
                AtlasSchemaV1.SubscribedChannel.self, AtlasSchemaV1.HistoryEntry.self,
                AtlasSchemaV1.Playlist.self, AtlasSchemaV1.PlaylistVideo.self,
            ])
            let configuration = ModelConfiguration(schema: older, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: older, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(
                AtlasSchemaV1.SubscribedChannel(
                    channelID: "legacy-channel", name: "Legacy creator", avatarURL: nil,
                    subscribedAt: Date(timeIntervalSince1970: 1_000)))
            context.insert(
                AtlasSchemaV1.HistoryEntry(
                    videoID: "legacy-video", title: "Legacy title", uploader: "Legacy creator",
                    watchedAt: Date(timeIntervalSince1970: 2_000), positionSeconds: 30, durationSeconds: 300))
            try context.save()
        }

        let container = try AtlasContainerFactory.make(url: url)
        let context = ModelContext(container)
        let channels = try context.fetch(FetchDescriptor<SubscribedChannel>())
        #expect(channels.map(\.channelID) == ["legacy-channel"])
        let history = try context.fetch(FetchDescriptor<HistoryEntry>())
        #expect(history.first?.videoID == "legacy-video")
        #expect(history.first?.positionSeconds == 30)
        // The current schema's additions are usable on the migrated store.
        context.insert(SyncPreference(key: "probe", value: "true"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<SyncPreference>()) == 1)
    }

    @Test func storeFromTheFrozenV1SchemaStillUsesTheStagedPlan() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try autoreleasepool {
            let schema = Schema(AtlasSchemaV1.models)
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(
                AtlasSchemaV1.SubscribedChannel(
                    channelID: "v1-channel", name: "V1 creator", avatarURL: nil,
                    subscribedAt: Date(timeIntervalSince1970: 1_000)))
            try context.save()
        }
        let container = try AtlasContainerFactory.make(url: url)
        let channels = try ModelContext(container).fetch(FetchDescriptor<SubscribedChannel>())
        #expect(channels.map(\.channelID) == ["v1-channel"])
    }
}
