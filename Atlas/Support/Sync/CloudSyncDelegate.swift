import CloudKit
import Foundation

/// Engine events reduced to what the coordinator acts on. `CKSyncEngine.Event` has
/// no public initializers, so tests drive `handle(_:)` with these values directly.
enum CloudSyncEngineEvent {
    case stateUpdate(Data)
    /// `nil` is a sign-out or a switch to an unknown user; the delegate compares a
    /// non-nil record name against the enrolled account.
    case accountChange(currentUserRecordName: String?)
    case fetchedDatabaseChanges(deletedZoneIDs: [CKRecordZone.ID])
    case fetchedRecordZoneChanges(modifications: [CKRecord])
    case sentRecordZoneChanges(
        savedRecords: [CKRecord],
        failedRecordSaves: [(record: CKRecord, error: CKError)],
        deletedRecordIDs: [CKRecord.ID],
        failedRecordDeletes: [CKRecord.ID: CKError])
    case didFetchRecordZoneChanges(error: Error?)
    case sentDatabaseChanges(error: Error?)
}

/// Each engine retains a distinct delegate/token. Cancelled engine callbacks can
/// never mutate a subsequently enrolled account or advance its checkpoint.
@MainActor
final class CloudSyncDelegate: CKSyncEngineDelegate {
    private weak var coordinator: CloudSyncCoordinator?
    private let sessionID: UUID

    init(coordinator: CloudSyncCoordinator, sessionID: UUID) {
        self.coordinator = coordinator
        self.sessionID = sessionID
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let coordinator, coordinator.engine?.nativeEngine === syncEngine else { return }
        let reduced: CloudSyncEngineEvent
        switch event {
        case .stateUpdate(let update):
            guard let data = try? JSONEncoder().encode(update.stateSerialization) else { return }
            reduced = .stateUpdate(data)
        case .accountChange(let change):
            switch change.changeType {
            case .signIn(let user): reduced = .accountChange(currentUserRecordName: user.recordName)
            case .switchAccounts(_, let user): reduced = .accountChange(currentUserRecordName: user.recordName)
            default: reduced = .accountChange(currentUserRecordName: nil)
            }
        case .fetchedDatabaseChanges(let changes):
            reduced = .fetchedDatabaseChanges(deletedZoneIDs: changes.deletions.map(\.zoneID))
        case .fetchedRecordZoneChanges(let changes):
            reduced = .fetchedRecordZoneChanges(modifications: changes.modifications.map(\.record))
        case .sentRecordZoneChanges(let changes):
            reduced = .sentRecordZoneChanges(
                savedRecords: changes.savedRecords,
                failedRecordSaves: changes.failedRecordSaves.map { ($0.record, $0.error) },
                deletedRecordIDs: changes.deletedRecordIDs,
                failedRecordDeletes: changes.failedRecordDeletes)
        case .didFetchRecordZoneChanges(let fetched):
            reduced = .didFetchRecordZoneChanges(error: fetched.error)
        case .sentDatabaseChanges(let changes):
            reduced = .sentDatabaseChanges(
                error: changes.failedZoneSaves.first?.error ?? changes.failedZoneDeletes.values.first)
        default:
            return
        }
        await handle(reduced)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let coordinator, coordinator.engine?.nativeEngine === syncEngine else { return nil }
        guard let batch = await nextBatch(inScope: { context.options.scope.contains($0) }) else { return nil }
        // Per-record success matters: one failure must not roll back unrelated
        // accepted revisions in the same library zone.
        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: batch.records, recordIDsToDelete: batch.deletions, atomicByZone: false)
    }

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        guard let coordinator, coordinator.sessionID == sessionID,
            let root = coordinator.root
        else { return .init(scope: .zoneIDs([])) }
        return .init(scope: .zoneIDs([CloudRecordCodec.libraryZoneID(for: root)]))
    }

    // MARK: Reduced events

    func handle(_ event: CloudSyncEngineEvent) async {
        guard let coordinator, coordinator.sessionID == sessionID, coordinator.isEnabled else { return }
        do {
            switch event {
            case .stateUpdate(let data):
                guard let namespace = coordinator.checkpointNamespace else { return }
                // Delegate events are awaited in order. Every preceding remote
                // application/ack has already committed before this token is saved.
                try coordinator.adapter.saveCheckpoint(data, namespace: namespace)
            case .accountChange(let currentUser):
                guard currentUser != coordinator.accountID else { return }
                // A sign-out or unknown user is verified against the container before
                // consent is discarded: a temporarily unavailable account only pauses.
                guard currentUser == nil else { throw CloudSyncError.accountChanged }
                await coordinator.accountMayHaveChanged()
            case .fetchedDatabaseChanges(let deletedZoneIDs):
                guard let root = coordinator.root else { return }
                let libraryZone = CloudRecordCodec.libraryZoneID(for: root)
                if deletedZoneIDs.contains(where: { $0 == libraryZone || $0 == CloudRecordCodec.controlZoneID }) {
                    throw CloudSyncError.cloudReset
                }
            case .fetchedRecordZoneChanges(let modifications):
                guard let root = coordinator.root else { return }
                try applyFetchedRecords(modifications, root: root, coordinator: coordinator)
                // Physical deletions are GC, not user actions. The encrypted
                // policy decides which materialized data is live. Unknown or
                // out-of-order deletions therefore never erase local rows. Our
                // bounded pending-GC queue is acknowledged by successful deletes
                // (including idempotent unknownItem responses) when sent.
                coordinator.refreshPendingCount()
            case .sentRecordZoneChanges(let saved, let failedSaves, let deletedIDs, let failedDeletes):
                guard let root = coordinator.root else { return }
                try acknowledgeSentChanges(
                    saved: saved, failedSaves: failedSaves, deletedIDs: deletedIDs,
                    failedDeletes: failedDeletes, root: root, coordinator: coordinator)
                // A newer mutation made during a save remains dirty after the old
                // revision's acknowledgement and is queued again here.
                try coordinator.queuePendingRecords()
            case .didFetchRecordZoneChanges(let error):
                if let error { coordinator.noteRoundFailure(error, token: sessionID) }
            case .sentDatabaseChanges(let error):
                if let error { coordinator.noteRoundFailure(error, token: sessionID) }
            }
        } catch {
            // Fencing suppresses all subsequent stateUpdate events, preserving the
            // last checkpoint from before the failed durable incoming transaction.
            coordinator.haltAfterDelegateFailure(error, token: sessionID)
        }
    }

    /// Policy first within each page; the adapter durably stages a child whose
    /// policy or playlist parent arrives on a later page. A record this version
    /// cannot apply is quarantined so the page (and the engine checkpoint) can
    /// still advance; only a protocol version this app does not understand halts.
    private func applyFetchedRecords(
        _ records: [CKRecord], root: SyncRoot, coordinator: CloudSyncCoordinator
    ) throws {
        var decoded: [(envelope: SyncEnvelope, record: CKRecord)] = []
        for record in records {
            do {
                decoded.append((try CloudRecordCodec.decode(record, root: root), record))
            } catch SyncProtocolError.unsupportedVersion {
                throw SyncProtocolError.unsupportedVersion
            } catch {
                try quarantine(record, error: error, coordinator: coordinator)
            }
        }
        decoded.sort { lhs, rhs in lhs.envelope.kind == .policy && rhs.envelope.kind != .policy }
        for (envelope, record) in decoded {
            do {
                _ = try coordinator.adapter.apply(
                    envelope, systemFields: try CloudRecordCodec.archiveSystemFields(record),
                    rebuildProjection: false)
                if coordinator.adapter.lastApplyChangedProjection { coordinator.hasIncomingChanges = true }
                if coordinator.quarantinedCount > 0 {
                    // A newer version that applies clears the item's earlier quarantine.
                    try coordinator.adapter.releaseQuarantine(recordName: record.recordID.recordName)
                    coordinator.noteQuarantine(nil)
                }
            } catch SyncProtocolError.unsupportedVersion {
                throw SyncProtocolError.unsupportedVersion
            } catch {
                try quarantine(record, error: error, coordinator: coordinator)
            }
        }
    }

    private func quarantine(_ record: CKRecord, error: Error, coordinator: CloudSyncCoordinator) throws {
        let payload = record.encryptedValues[CloudRecordCodec.payloadField] as? Data ?? Data()
        try coordinator.adapter.quarantine(
            recordName: record.recordID.recordName, payload: payload,
            systemFields: try CloudRecordCodec.archiveSystemFields(record),
            reason: Self.reason(for: error))
        coordinator.noteQuarantine(error)
    }

    private func acknowledgeSentChanges(
        saved: [CKRecord], failedSaves: [(record: CKRecord, error: CKError)],
        deletedIDs: [CKRecord.ID], failedDeletes: [CKRecord.ID: CKError],
        root: SyncRoot, coordinator: CloudSyncCoordinator
    ) throws {
        for record in saved {
            guard let sent = coordinator.inFlight.removeValue(forKey: record.recordID) else { continue }
            try coordinator.adapter.acknowledge(
                key: sent.key, revision: sent.revision,
                systemFields: try CloudRecordCodec.archiveSystemFields(record))
        }
        for id in deletedIDs {
            if let key = coordinator.deletionsInFlight.removeValue(forKey: id) {
                try coordinator.adapter.acknowledgeDeletion(key: key)
            }
        }
        for (id, error) in failedDeletes {
            guard let key = coordinator.deletionsInFlight.removeValue(forKey: id) else { continue }
            if error.code == .unknownItem {
                try coordinator.adapter.acknowledgeDeletion(key: key)
                coordinator.engine?.removeDeletions([id])
            } else if Self.isRoundLevel(error.code) {
                coordinator.noteRoundFailure(error, token: sessionID)
            } else {
                coordinator.noteItemFailure(error, key: key, token: sessionID)
            }
        }
        for failed in failedSaves {
            guard let sent = coordinator.inFlight.removeValue(forKey: failed.record.recordID) else { continue }
            switch failed.error.code {
            case .serverRecordChanged:
                guard let serverRecord = failed.error.serverRecord else {
                    coordinator.noteItemFailure(failed.error, key: sent.key, token: sessionID)
                    continue
                }
                do {
                    let serverEnvelope = try CloudRecordCodec.decode(serverRecord, root: root)
                    _ = try coordinator.adapter.apply(
                        serverEnvelope, systemFields: try CloudRecordCodec.archiveSystemFields(serverRecord),
                        rebuildProjection: false)
                    coordinator.conflictsNeedProjection = true
                    if coordinator.adapter.lastApplyChangedProjection { coordinator.hasIncomingChanges = true }
                } catch SyncProtocolError.unsupportedVersion {
                    throw SyncProtocolError.unsupportedVersion
                } catch {
                    // The server copy cannot be merged by this version; leave both
                    // copies intact and stop retrying this one item for the session.
                    coordinator.noteItemFailure(error, key: sent.key, token: sessionID)
                }
            case .unknownItem:
                // Our saved change tag describes a record another device has since
                // collected. Forget the tag; the next round recreates the record.
                try coordinator.adapter.clearSystemFields(key: sent.key)
            default:
                if Self.isRoundLevel(failed.error.code) {
                    coordinator.noteRoundFailure(failed.error, token: sessionID)
                } else {
                    coordinator.noteItemFailure(failed.error, key: sent.key, token: sessionID)
                }
            }
        }
    }

    /// Returns nil when nothing remains to send. In-flight and poisoned journal
    /// keys are skipped, so a rejected record never blocks the rest of the queue.
    func nextBatch(inScope: (CKRecord.ID) -> Bool) async -> (records: [CKRecord], deletions: [CKRecord.ID])? {
        guard let coordinator, coordinator.sessionID == sessionID,
            coordinator.isEnabled, coordinator.allowsSending, let root = coordinator.root
        else { return nil }
        do {
            let excluded = Set(coordinator.inFlight.values.map(\.key)).union(coordinator.poisonedKeys)
            let pending = try coordinator.adapter.pendingRecords(
                limit: coordinator.batchRecordLimit, byteLimit: coordinator.batchByteLimit, excluding: excluded)
            // A clear's encrypted barrier must be acknowledged before physical
            // cleanup. Other replicas can then reject any late stale upload.
            let hasPendingPolicy = try coordinator.adapter.hasPendingBarriers(excluding: coordinator.poisonedKeys)
            var records: [CKRecord] = []
            for mutation in pending {
                let isBarrier =
                    mutation.envelope.kind == .policy
                    || (mutation.envelope.kind == .activity
                        && mutation.envelope.entityID == RecommendationSyncBridge.retentionEntityID)
                if hasPendingPolicy && !isBarrier { continue }
                let id = try CloudRecordCodec.recordID(for: mutation.envelope, root: root)
                guard inScope(id) else { continue }
                do {
                    let prior = try mutation.systemFields.map { try CloudRecordCodec.restoreSystemFields($0) }
                    records.append(try CloudRecordCodec.encode(mutation.envelope, root: root, reusing: prior))
                    coordinator.inFlight[id] = mutation
                } catch SyncProtocolError.invalidSystemFields {
                    // Unreadable archived metadata: drop it and send the record fresh.
                    try coordinator.adapter.clearSystemFields(key: mutation.key)
                    records.append(try CloudRecordCodec.encode(mutation.envelope, root: root))
                    coordinator.inFlight[id] = mutation
                } catch {
                    coordinator.noteItemFailure(error, key: mutation.key, token: sessionID)
                }
            }
            var deletionIDs: [CKRecord.ID] = []
            if !hasPendingPolicy, records.count < coordinator.batchRecordLimit {
                let inFlightDeletions = Set(coordinator.deletionsInFlight.values)
                for deletion in try coordinator.adapter.pendingDeletions(
                    limit: coordinator.batchRecordLimit - records.count + inFlightDeletions.count)
                where !inFlightDeletions.contains(deletion.key) && !coordinator.poisonedKeys.contains(deletion.key) {
                    let id = try CloudRecordCodec.recordID(for: deletion.envelope, root: root)
                    guard inScope(id) else { continue }
                    deletionIDs.append(id)
                    coordinator.deletionsInFlight[id] = deletion.key
                    if records.count + deletionIDs.count >= coordinator.batchRecordLimit { break }
                }
            }
            guard !records.isEmpty || !deletionIDs.isEmpty else {
                coordinator.engine?.setUntrackedChanges(false)
                return nil
            }
            return (records, deletionIDs)
        } catch {
            coordinator.haltAfterDelegateFailure(error, token: sessionID)
            return nil
        }
    }

    /// Errors that describe the zone, account, or service rather than one record.
    static func isRoundLevel(_ code: CKError.Code) -> Bool {
        switch code {
        case .zoneNotFound, .userDeletedZone, .quotaExceeded, .notAuthenticated,
            .accountTemporarilyUnavailable, .networkFailure, .networkUnavailable,
            .serviceUnavailable, .requestRateLimited, .zoneBusy, .limitExceeded,
            .changeTokenExpired, .batchRequestFailed, .operationCancelled,
            .managedAccountRestricted, .permissionFailure, .incompatibleVersion:
            return true
        default:
            return false
        }
    }

    /// Bounded, payload-free description for the quarantine row and status text.
    static func reason(for error: Error) -> String {
        if let error = error as? SyncProtocolError { return "protocol.\(error)" }
        if let error = error as? SyncStorageError {
            if case .capacityExceeded(let label) = error { return "capacity.\(label)" }
            return "storage.\(error)"
        }
        return "other"
    }
}
