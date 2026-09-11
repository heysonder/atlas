import Foundation
import SwiftData

/// CloudKit transport is opt-in and owned by CloudSyncCoordinator. SwiftData
/// must never infer mirroring from the app's iCloud entitlements, including
/// when a headless App Intent opens the library.
@MainActor
enum AtlasContainerFactory {
    static func configuration(
        schema: Schema = AtlasModelSchema.schema,
        inMemory: Bool = false,
        url: URL? = nil
    ) -> ModelConfiguration {
        if let url {
            return ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        }
        return ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
    }

    static func make(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: AtlasSchemaV2.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: AtlasSchemaMigrationPlan.self,
            configurations: [configuration(schema: schema, inMemory: inMemory, url: url)])
    }
}
