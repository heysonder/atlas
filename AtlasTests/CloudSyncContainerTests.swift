import Foundation
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func cloudSyncLocalConfigurationsNeverUseAutomaticMirroring() throws {
    let disk = AtlasContainerFactory.configuration()
    let memory = AtlasContainerFactory.configuration(inMemory: true)
    #expect(disk.cloudKitContainerIdentifier == nil)
    #expect(memory.cloudKitContainerIdentifier == nil)
    #expect(memory.isStoredInMemoryOnly)
    // The opt-out must not silently move the existing library to a new file.
    let previous = ModelConfiguration(schema: AtlasModelSchema.schema)
    #expect(disk.url == previous.url)
}

@MainActor
@Test func cloudSyncRecoveryContainerKeepsSyncUnavailable() throws {
    let container = try AtlasContainerFactory.make(inMemory: true)
    let sync = CloudSyncCoordinator(context: container.mainContext, persistenceAvailable: false)
    #expect(!sync.isAvailable)
    #expect(!sync.isEnabled)
}

@MainActor
@Test func cloudSyncMetadataLivesAlongsideTheLibrary() throws {
    let names = Set(AtlasModelSchema.modelTypes.map { String(describing: $0) })
    for expected in [
        "SyncRecordState", "SyncEnrollment", "SyncCheckpoint", "SyncPreference",
        "FeedImpressionBaseline", "RecommendationActivityState",
    ] {
        #expect(names.contains(expected))
    }
}
