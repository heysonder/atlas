import CloudKit
import Foundation

/// Created lazily, only after explicit consent or validated device-bound enrollment.
@MainActor
protocol CloudSyncTransport: AnyObject {
    func accountID() async throws -> String
    func fetchRecord(_ id: CKRecord.ID) async throws -> CKRecord
    func saveRecordConditionally(_ record: CKRecord) async throws -> CKRecord
    func createZone(_ id: CKRecordZone.ID) async throws
    func verifyZone(_ id: CKRecordZone.ID) async throws
    func deleteZone(_ id: CKRecordZone.ID) async throws
    func makeEngine(serialization: CKSyncEngine.State.Serialization?, delegate: CloudSyncDelegate)
        -> any CloudSyncEngineSession
}

@MainActor
protocol CloudSyncEngineSession: AnyObject {
    var nativeEngine: CKSyncEngine? { get }
    func fetchChanges(in zoneID: CKRecordZone.ID) async throws
    func sendChanges(in zoneID: CKRecordZone.ID) async throws
    func cancel() async
    func enqueue(_ ids: [CKRecord.ID])
    func remove(_ ids: [CKRecord.ID])
    func enqueueDeletions(_ ids: [CKRecord.ID])
    func removeDeletions(_ ids: [CKRecord.ID])
    func setUntrackedChanges(_ value: Bool)
}

final class PrivateCloudSyncTransport: CloudSyncTransport {
    static let containerIdentifier = "iCloud.sh.cmf.atlas"
    private let container: CKContainer
    private let database: CKDatabase

    init() {
        let container = CKContainer(identifier: Self.containerIdentifier)
        self.container = container
        database = container.privateCloudDatabase
    }

    func accountID() async throws -> String {
        let status = try await container.accountStatus()
        guard status == .available else { throw CloudSyncError.accountUnavailable }
        return try await container.userRecordID().recordName
    }

    func fetchRecord(_ id: CKRecord.ID) async throws -> CKRecord {
        try await database.record(for: id)
    }

    func saveRecordConditionally(_ record: CKRecord) async throws -> CKRecord {
        let result = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
        )
        guard let saved = result.saveResults[record.recordID] else {
            throw CloudSyncError.incompleteResponse
        }
        return try saved.get()
    }

    func createZone(_ id: CKRecordZone.ID) async throws {
        _ = try await database.save(CKRecordZone(zoneID: id))
    }

    func verifyZone(_ id: CKRecordZone.ID) async throws {
        _ = try await database.recordZone(for: id)
    }

    func deleteZone(_ id: CKRecordZone.ID) async throws {
        do {
            _ = try await database.deleteRecordZone(withID: id)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            // Idempotent retry after a crash between deletion and local checkpoint.
        }
    }

    func makeEngine(serialization: CKSyncEngine.State.Serialization?, delegate: CloudSyncDelegate)
        -> any CloudSyncEngineSession
    {
        var configuration = CKSyncEngine.Configuration(
            database: database, stateSerialization: serialization, delegate: delegate
        )
        // Foreground, push, and manual catch-up always validate account and root
        // before fetching and sending. CKSyncEngine owns tokens and batch retries.
        configuration.automaticallySync = false
        return PrivateCloudSyncEngineSession(engine: CKSyncEngine(configuration))
    }
}

private final class PrivateCloudSyncEngineSession: CloudSyncEngineSession {
    let engine: CKSyncEngine
    var nativeEngine: CKSyncEngine? { engine }

    init(engine: CKSyncEngine) { self.engine = engine }

    func fetchChanges(in zoneID: CKRecordZone.ID) async throws {
        try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
    }

    func sendChanges(in zoneID: CKRecordZone.ID) async throws {
        try await engine.sendChanges(.init(scope: .zoneIDs([zoneID])))
    }

    func cancel() async { await engine.cancelOperations() }
    func enqueue(_ ids: [CKRecord.ID]) {
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
    }
    func remove(_ ids: [CKRecord.ID]) {
        engine.state.remove(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
    }
    func enqueueDeletions(_ ids: [CKRecord.ID]) {
        engine.state.add(pendingRecordZoneChanges: ids.map { .deleteRecord($0) })
    }
    func removeDeletions(_ ids: [CKRecord.ID]) {
        engine.state.remove(pendingRecordZoneChanges: ids.map { .deleteRecord($0) })
    }
    func setUntrackedChanges(_ value: Bool) { engine.state.hasPendingUntrackedChanges = value }
}

enum CloudSyncError: LocalizedError, Equatable {
    case accountUnavailable
    case accountChanged
    case cloudReset
    case persistenceUnavailable
    case unsupportedProtocol
    case incompleteResponse
    case cancelled
    case missingEnrollment
    case unrecognizedDeletion

    var errorDescription: String? {
        switch self {
        case .accountUnavailable:
            "Sign in to iCloud in Settings, then try again. Your local data is preserved."
        case .accountChanged:
            "The Apple Account changed. Review the encryption notice and explicitly enable sync to merge this device with the current account."
        case .cloudReset:
            "Atlas’s iCloud library was reset or removed. Sync is paused. Enable sync again only if you want to upload this device’s library as a new cloud library."
        case .persistenceUnavailable:
            "Sync is unavailable while Atlas is using its temporary recovery library. Restore access to the saved library first."
        case .unsupportedProtocol:
            "This iCloud library needs a newer version of Atlas. Update Atlas before syncing."
        case .incompleteResponse:
            "iCloud did not finish the request. Your local changes are still saved; try again later."
        case .cancelled:
            "Sync was stopped."
        case .missingEnrollment:
            "This device has no previously linked iCloud library to delete."
        case .unrecognizedDeletion:
            "An iCloud record was removed outside Atlas’s sync protocol. Sync has paused to protect local changes."
        }
    }
}
