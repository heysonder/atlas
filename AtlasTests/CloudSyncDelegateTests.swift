import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Atlas

// Drives the engine delegate with reduced events (CKSyncEngine.Event has no public
// initializers), so page application, acknowledgements, per-record failures, and
// checkpoint ordering run against the real coordinator and adapter.

@MainActor
private final class DelegateTestIdentity: SyncInstallationIdentityStoring {
    func existingIdentity() throws -> String? { "device-one" }
    func identityForConsent() throws -> String { "device-one" }
}

@MainActor
private final class DelegateTestEngine: CloudSyncEngineSession {
    var nativeEngine: CKSyncEngine? { nil }
    var fetchCount = 0
    var sendCount = 0
    var queued: [CKRecord.ID] = []
    var queuedDeletions: [CKRecord.ID] = []
    func fetchChanges(in zoneID: CKRecordZone.ID) async throws { fetchCount += 1 }
    func sendChanges(in zoneID: CKRecordZone.ID) async throws { sendCount += 1 }
    func cancel() async {}
    func enqueue(_ ids: [CKRecord.ID]) { queued.append(contentsOf: ids) }
    func remove(_ ids: [CKRecord.ID]) { queued.removeAll { ids.contains($0) } }
    func enqueueDeletions(_ ids: [CKRecord.ID]) { queuedDeletions.append(contentsOf: ids) }
    func removeDeletions(_ ids: [CKRecord.ID]) { queuedDeletions.removeAll { ids.contains($0) } }
    func setUntrackedChanges(_ value: Bool) {}
}

@MainActor
private final class DelegateTestTransport: CloudSyncTransport {
    var user = "account-one"
    var rootRecord: CKRecord?
    var accountFailure: Error?
    var deletedZones: [CKRecordZone.ID] = []
    let engine = DelegateTestEngine()

    func accountID() async throws -> String {
        if let accountFailure { throw accountFailure }
        return user
    }
    func fetchRecord(_ id: CKRecord.ID) async throws -> CKRecord {
        guard let rootRecord else { throw CKError(.unknownItem) }
        return rootRecord.copy() as! CKRecord
    }
    func saveRecordConditionally(_ record: CKRecord) async throws -> CKRecord {
        rootRecord = record
        return record
    }
    func createZone(_ id: CKRecordZone.ID) async throws {}
    func verifyZone(_ id: CKRecordZone.ID) async throws {}
    func deleteZone(_ id: CKRecordZone.ID) async throws { deletedZones.append(id) }
    func makeEngine(serialization: CKSyncEngine.State.Serialization?, delegate: CloudSyncDelegate)
        -> any CloudSyncEngineSession
    {
        engine
    }
}

@MainActor
private struct Session {
    let container: ModelContainer
    let transport: DelegateTestTransport
    let coordinator: CloudSyncCoordinator
    let delegate: CloudSyncDelegate
    let root: SyncRoot

    var context: ModelContext { container.mainContext }

    static func start() async throws -> Session {
        let container = try makeTestContainer()
        let transport = DelegateTestTransport()
        let root = SyncRoot()
        transport.rootRecord = try CloudRecordCodec.encodeRoot(root)
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: DelegateTestIdentity(),
            registerForRemoteNotifications: {}
        ) { transport }
        await coordinator.enable()
        try #require(coordinator.isEnabled)
        let delegate = try #require(coordinator.engineDelegate)
        // The fake engine never acknowledges anything by itself. Acknowledge the
        // initial retention barrier so ordinary records are eligible for batches.
        coordinator.allowsSending = true
        if let barrier = await delegate.nextBatch(inScope: { _ in true }) {
            await delegate.handle(
                .sentRecordZoneChanges(
                    savedRecords: barrier.records, failedRecordSaves: [],
                    deletedRecordIDs: barrier.deletions, failedRecordDeletes: [:]))
        }
        #expect(!(try coordinator.adapter.hasPendingBarriers()))
        return Session(
            container: container, transport: transport, coordinator: coordinator, delegate: delegate, root: root)
    }

    /// A record as another device would have written it.
    func remoteRecord(channelID: String, name: String, writer: String = "remote:1", counter: UInt64 = 1) throws
        -> CKRecord
    {
        let payload = try SyncPayload.encode(
            SyncSubscriptionPayload(
                channelID: channelID, name: name, avatarURL: nil, subscribedAt: Date(timeIntervalSince1970: 1_000)))
        let envelope = try SyncEnvelope.mutation(
            kind: .subscription, entityID: channelID, payload: payload, writerID: writer, counter: counter)
        return try CloudRecordCodec.encode(envelope, root: root)
    }

    func subscribe(_ channelID: String, name: String) {
        SubscriptionStore.setSubscribed(true, channelID: channelID, name: name, avatarURL: nil, in: context)
    }

    func subscription(_ channelID: String) throws -> SubscribedChannel? {
        try context.fetch(FetchDescriptor<SubscribedChannel>(predicate: #Predicate { $0.channelID == channelID })).first
    }

    func nextBatch() async -> (records: [CKRecord], deletions: [CKRecord.ID])? {
        coordinator.allowsSending = true
        return await delegate.nextBatch(inScope: { _ in true })
    }
}

@Suite(.serialized)
struct CloudSyncDelegateTests {

    @MainActor
    @Test func malformedFetchedRecordIsQuarantinedAndThePageStillApplies() async throws {
        let session = try await Session.start()
        let bad = CKRecord(
            recordType: CloudRecordCodec.itemRecordType,
            recordID: CKRecord.ID(
                recordName: "not-a-real-name", zoneID: CloudRecordCodec.libraryZoneID(for: session.root)))
        bad.encryptedValues[CloudRecordCodec.payloadField] = Data("{\"nope\":1}".utf8) as NSData
        let good = try session.remoteRecord(channelID: "good-channel", name: "Good")

        await session.delegate.handle(.fetchedRecordZoneChanges(modifications: [bad, good]))
        await session.delegate.handle(.stateUpdate(Data("{\"token\":1}".utf8)))

        #expect(session.coordinator.isEnabled)
        #expect(session.coordinator.engine != nil)
        #expect(try session.subscription("good-channel")?.name == "Good")
        #expect(session.coordinator.quarantinedCount == 1)
        #expect(try session.coordinator.adapter.quarantinedRecords().first?.recordName == "not-a-real-name")
        // The checkpoint advanced past the bad record instead of replaying the page forever.
        let namespace = try #require(session.coordinator.checkpointNamespace)
        #expect(try session.coordinator.adapter.loadCheckpoint(namespace: namespace) == Data("{\"token\":1}".utf8))
        await session.coordinator.disable()
    }

    @MainActor
    @Test func unsupportedProtocolVersionHaltsInsteadOfQuarantining() async throws {
        let session = try await Session.start()
        let record = try session.remoteRecord(channelID: "future-channel", name: "Future")
        var object = try #require(
            JSONSerialization.jsonObject(
                with: record.encryptedValues[CloudRecordCodec.payloadField] as! Data) as? [String: Any])
        object["schemaVersion"] = SyncEnvelope.currentSchemaVersion + 1
        record.encryptedValues[CloudRecordCodec.payloadField] =
            try JSONSerialization.data(withJSONObject: object) as NSData

        await session.delegate.handle(.fetchedRecordZoneChanges(modifications: [record]))
        await session.delegate.handle(.stateUpdate(Data("{\"token\":2}".utf8)))

        #expect(session.coordinator.engine == nil)
        #expect(session.coordinator.statusText == "Needs Attention")
        #expect(session.coordinator.quarantinedCount == 0)
        #expect(try session.subscription("future-channel") == nil)
        // Fenced: the checkpoint from after the failed page is not persisted.
        let checkpoints = try session.context.fetch(FetchDescriptor<SyncCheckpoint>())
        #expect(!checkpoints.contains { $0.data == Data("{\"token\":2}".utf8) })
        await session.coordinator.disable()
    }

    @MainActor
    @Test func serverRecordChangedMergesTheServerCopyAndRequeues() async throws {
        let session = try await Session.start()
        session.subscribe("shared-channel", name: "Local name")
        let batch = try #require(await session.nextBatch())
        let local = try #require(batch.records.first)
        let server = try session.remoteRecord(channelID: "shared-channel", name: "Remote name")
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

        await session.delegate.handle(
            .sentRecordZoneChanges(
                savedRecords: [], failedRecordSaves: [(local, conflict)], deletedRecordIDs: [], failedRecordDeletes: [:]
            ))

        #expect(session.coordinator.isEnabled)
        #expect(session.coordinator.inFlight.isEmpty)
        #expect(session.coordinator.conflictsNeedProjection)
        let pending = try session.coordinator.adapter.pendingRecords()
        let merged = try #require(pending.first { $0.envelope.entityID == "shared-channel" })
        // Both concurrent versions survive in the register and the merged state is dirty again.
        #expect(merged.envelope.register.versions.count == 2)
        #expect(merged.systemFields != nil)
        await session.coordinator.disable()
    }

    @MainActor
    @Test func unknownItemOnSaveForgetsTheStaleChangeTagAndRetries() async throws {
        let session = try await Session.start()
        session.subscribe("collected-channel", name: "First")
        let first = try #require(await session.nextBatch()).records.first!
        // A prior successful save left a change tag behind.
        await session.delegate.handle(
            .sentRecordZoneChanges(
                savedRecords: [first], failedRecordSaves: [], deletedRecordIDs: [], failedRecordDeletes: [:]))
        SubscriptionStore.setSubscribed(
            true, channelID: "collected-channel", name: "Second", avatarURL: nil, in: session.context)
        let before = try #require(
            try session.coordinator.adapter.pendingRecords().first { $0.envelope.entityID == "collected-channel" })
        #expect(before.systemFields != nil)
        let retry = try #require(await session.nextBatch()).records.first!

        await session.delegate.handle(
            .sentRecordZoneChanges(
                savedRecords: [], failedRecordSaves: [(retry, CKError(.unknownItem))], deletedRecordIDs: [],
                failedRecordDeletes: [:]))

        let after = try #require(
            try session.coordinator.adapter.pendingRecords().first { $0.envelope.entityID == "collected-channel" })
        #expect(after.systemFields == nil)
        #expect(session.coordinator.isEnabled)
        #expect(session.coordinator.poisonedKeys.isEmpty)
        await session.coordinator.disable()
    }

    @MainActor
    @Test func aRejectedRecordDoesNotBlockTheRestOfTheQueue() async throws {
        let session = try await Session.start()
        session.subscribe("rejected-channel", name: "Rejected")
        session.subscribe("accepted-channel", name: "Accepted")
        let batch = try #require(await session.nextBatch())
        #expect(batch.records.count == 2)
        let rejected = try #require(
            session.coordinator.inFlight.first { $0.value.envelope.entityID == "rejected-channel" })
        let accepted = try #require(
            session.coordinator.inFlight.first { $0.value.envelope.entityID == "accepted-channel" })
        let rejectedRecord = batch.records.first { $0.recordID == rejected.key }!
        let acceptedRecord = batch.records.first { $0.recordID == accepted.key }!

        await session.delegate.handle(
            .sentRecordZoneChanges(
                savedRecords: [acceptedRecord], failedRecordSaves: [(rejectedRecord, CKError(.invalidArguments))],
                deletedRecordIDs: [], failedRecordDeletes: [:]))

        #expect(session.coordinator.isEnabled)
        #expect(session.coordinator.allowsSending)
        #expect(session.coordinator.poisonedKeys == [rejected.value.key])
        let pending = try session.coordinator.adapter.pendingRecords()
        #expect(pending.contains { $0.envelope.entityID == "rejected-channel" })
        #expect(!pending.contains { $0.envelope.entityID == "accepted-channel" })
        // The poisoned item is skipped for the rest of the session; nothing else remains.
        #expect(await session.nextBatch() == nil)
        await session.coordinator.disable()
    }

    @MainActor
    @Test func aZoneLevelErrorStillStopsTheRound() async throws {
        let session = try await Session.start()
        session.subscribe("quota-channel", name: "Quota")
        let record = try #require(await session.nextBatch()).records.first!

        await session.delegate.handle(
            .sentRecordZoneChanges(
                savedRecords: [], failedRecordSaves: [(record, CKError(.quotaExceeded))], deletedRecordIDs: [],
                failedRecordDeletes: [:]))

        #expect(!session.coordinator.allowsSending)
        #expect(session.coordinator.statusText == "iCloud Storage Full")
        #expect(session.coordinator.poisonedKeys.isEmpty)
        await session.coordinator.disable()
    }

    @MainActor
    @Test func accountChangeNotificationForTheSameAccountKeepsEnrollment() async throws {
        let session = try await Session.start()
        await session.coordinator.accountMayHaveChanged()
        #expect(session.coordinator.isEnabled)
        #expect(try session.coordinator.adapter.enrollment().optedIn)

        session.transport.accountFailure = CKError(.accountTemporarilyUnavailable)
        await session.coordinator.accountMayHaveChanged()
        #expect(session.coordinator.isEnabled)
        #expect(try session.coordinator.adapter.enrollment().optedIn)
        session.transport.accountFailure = nil

        session.transport.user = "account-two"
        await session.coordinator.accountMayHaveChanged()
        #expect(!session.coordinator.isEnabled)
        #expect(session.coordinator.statusText == "Account Changed")
        #expect(!(try session.coordinator.adapter.enrollment().optedIn))
    }

    @MainActor
    @Test func progressWritesAreBatchedAndFlushedAtBoundaries() async throws {
        let session = try await Session.start()
        session.coordinator.coalescedSyncInterval = 1.0
        session.coordinator.journalDebounce = 0.1
        session.coordinator.sceneInactive()
        await session.coordinator.sceneActive()
        let engine = session.transport.engine
        // Let anything the session start scheduled settle before measuring.
        try await Task.sleep(for: .milliseconds(300))

        var sendsBefore = engine.sendCount
        try LibrarySyncJournal.transaction(in: session.context, captureChanges: false, coalesceSync: true) {
            session.subscribe("tick-channel", name: "Tick")
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(
            engine.sendCount == sendsBefore,
            "a batched progress write started a round immediately (isWorking \(session.coordinator.isWorking))")
        var deadline = Date().addingTimeInterval(3)
        while engine.sendCount == sendsBefore, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(engine.sendCount > sendsBefore)

        sendsBefore = engine.sendCount
        try LibrarySyncJournal.transaction(in: session.context, captureChanges: false, coalesceSync: false) {
            session.subscribe("flush-channel", name: "Flush")
        }
        deadline = Date().addingTimeInterval(1.5)
        while engine.sendCount == sendsBefore, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(engine.sendCount > sendsBefore)
        await session.coordinator.disable()
    }

    @MainActor
    @Test func aRejectedBarrierDoesNotBlockOtherUploads() async throws {
        let session = try await Session.start()
        // A clear writes an encrypted policy barrier that must precede other records.
        #expect(PlaybackHistoryStore.clear(in: session.context))
        session.subscribe("after-clear", name: "After")
        let first = try #require(await session.nextBatch())
        #expect(first.records.count == 1)
        let barrier = try #require(session.coordinator.inFlight.first)
        #expect(barrier.value.envelope.kind == .policy)

        await session.delegate.handle(
            .sentRecordZoneChanges(
                savedRecords: [], failedRecordSaves: [(first.records[0], CKError(.invalidArguments))],
                deletedRecordIDs: [], failedRecordDeletes: [:]))
        #expect(session.coordinator.poisonedKeys == [barrier.value.key])

        // The poisoned barrier no longer holds the queue: the subscription goes out.
        let second = try #require(await session.nextBatch())
        #expect(second.records.count == 1)
        #expect(session.coordinator.inFlight.values.contains { $0.envelope.entityID == "after-clear" })
        await session.coordinator.disable()
    }

    @MainActor
    @Test func progressWritesDuringARoundKeepTheirBatchingInterval() async throws {
        let session = try await Session.start()
        session.coordinator.coalescedSyncInterval = 1.0
        session.coordinator.journalDebounce = 0.1
        session.coordinator.sceneInactive()
        await session.coordinator.sceneActive()
        let engine = session.transport.engine
        try await Task.sleep(for: .milliseconds(300))
        let sendsBefore = engine.sendCount
        // Journal a progress tick while a round is marked in flight.
        let syncing = Task { @MainActor in await session.coordinator.syncNow() }
        try LibrarySyncJournal.transaction(in: session.context, captureChanges: false, coalesceSync: true) {
            session.subscribe("mid-round-tick", name: "Tick")
        }
        await syncing.value
        #expect(engine.sendCount == sendsBefore + 1)
        // The tick waits out the batching interval instead of the edit debounce.
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.sendCount == sendsBefore + 1)
        let deadline = Date().addingTimeInterval(3)
        while engine.sendCount == sendsBefore + 1, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(engine.sendCount == sendsBefore + 2)
        await session.coordinator.disable()
    }

    @MainActor
    @Test func editsDuringARoundGetTheirOwnRound() async throws {
        let session = try await Session.start()
        session.coordinator.journalDebounce = 0.1
        session.coordinator.sceneInactive()
        await session.coordinator.sceneActive()
        let engine = session.transport.engine
        let sendsBefore = engine.sendCount
        // Journal while a round is marked in flight, then let the round end.
        let syncing = Task { @MainActor in await session.coordinator.syncNow() }
        session.subscribe("mid-round-channel", name: "Mid")
        await syncing.value
        let deadline = Date().addingTimeInterval(2)
        while engine.sendCount < sendsBefore + 2, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(engine.sendCount >= sendsBefore + 1)
        await session.coordinator.disable()
    }

    @MainActor
    @Test func failedCloudDeletionIsReportedAsUnfinishedAndStaysRetryable() async throws {
        let session = try await Session.start()
        session.transport.accountFailure = CKError(.networkUnavailable)
        await session.coordinator.deleteCloudContent()
        #expect(session.coordinator.statusText == "Deletion Not Finished")
        #expect(try session.coordinator.adapter.enrollment().phase == "deleteFailed")
        #expect(!session.coordinator.isEnabled)
        #expect(session.coordinator.hasLinkedLibrary)
        #expect(session.transport.deletedZones.isEmpty)

        session.transport.accountFailure = nil
        await session.coordinator.deleteCloudContent()
        #expect(session.coordinator.statusText == "iCloud Content Deleted")
        #expect(try session.coordinator.adapter.enrollment().phase == "deleted")
        #expect(session.transport.deletedZones.contains(CloudRecordCodec.libraryZoneID(for: session.root)))
    }

    @MainActor
    @Test func reEnablingAfterAnInterruptedDeletionRemovesTheOrphanedZone() async throws {
        let container = try makeTestContainer()
        let transport = DelegateTestTransport()
        let disabledRoot = SyncRoot(disabled: true)
        transport.rootRecord = try CloudRecordCodec.encodeRoot(disabledRoot)
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: DelegateTestIdentity(),
            registerForRemoteNotifications: {}
        ) { transport }
        await coordinator.enable()
        #expect(coordinator.isEnabled)
        #expect(transport.deletedZones.contains(CloudRecordCodec.libraryZoneID(for: disabledRoot)))
        #expect(coordinator.root?.libraryGeneration != disabledRoot.libraryGeneration)
        await coordinator.disable()
    }

    @MainActor
    @Test func acknowledgedActivityTombstonesAreCompactedIntoDeletions() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let adapter = SyncStoreAdapter(context: context)
        try adapter.bind(accountID: "account", libraryGeneration: "library")
        let uploaded = UUID().uuidString.lowercased()
        let neverUploaded = UUID().uuidString.lowercased()
        try LibrarySyncJournal.transaction(in: context, captureChanges: false, notifySync: false) {
            try LibrarySyncJournal.record(kind: .activity, entityID: uploaded, payload: nil, in: context)
            try LibrarySyncJournal.record(kind: .activity, entityID: neverUploaded, payload: nil, in: context)
        }
        let uploadedRow = try #require(try adapter.state(kind: .activity, entityID: uploaded))
        try adapter.acknowledge(
            key: uploadedRow.key, revision: uploadedRow.localRevision, systemFields: Data([1, 2, 3]))

        try adapter.finishIncomingBatch(force: true)

        let deletions = try adapter.pendingDeletions().map(\.envelope.entityID)
        #expect(deletions.contains(uploaded))
        #expect(deletions.contains(neverUploaded))
        #expect(
            try adapter.pendingRecords().allSatisfy {
                $0.envelope.entityID != uploaded && $0.envelope.entityID != neverUploaded
            })
        // CloudKit confirming the deletion (or reporting it already gone) drops the row.
        for key in try adapter.pendingDeletions().map(\.key) { try adapter.acknowledgeDeletion(key: key) }
        #expect(try adapter.state(kind: .activity, entityID: uploaded) == nil)
        #expect(try adapter.state(kind: .activity, entityID: neverUploaded) == nil)
        #expect(try adapter.pendingDeletions().isEmpty)
    }

}
