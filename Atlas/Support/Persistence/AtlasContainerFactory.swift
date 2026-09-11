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

    /// Opens the library with the staged migration plan first. A store written by
    /// a build whose models predate the frozen `AtlasSchemaV1` (older TestFlight
    /// installs) has a model version the plan does not know, and SwiftData refuses
    /// it outright. Every schema change since then is additive, so the second
    /// attempt lets SwiftData infer a lightweight migration from whatever the
    /// store actually contains instead of abandoning the user's library.
    static func make(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: AtlasSchemaV2.self)
        let configuration = configuration(schema: schema, inMemory: inMemory, url: url)
        do {
            return try ModelContainer(
                for: schema, migrationPlan: AtlasSchemaMigrationPlan.self, configurations: [configuration])
        } catch let plannedError {
            guard !inMemory else { throw plannedError }
            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                throw ContainerOpenFailure(planned: plannedError, inferred: error)
            }
        }
    }

    /// Both attempts failed; the caller decides whether to fall back to recovery storage.
    struct ContainerOpenFailure: Error, CustomStringConvertible {
        let planned: Error
        let inferred: Error
        var description: String {
            "staged migration: \(planned); inferred migration: \(inferred)"
        }
    }
}
