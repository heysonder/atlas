import CloudKit
import Foundation
import Observation
import SwiftData
import UIKit

/// Owns the only sync engine for the UI process. Local stores remain the source
/// of truth; this object only releases durable journal revisions to CloudKit.
@Observable
@MainActor
final class CloudSyncCoordinator {
    private(set) var statusText = "Off"
    private(set) var detailText: String?
    private(set) var isEnabled = false
    private(set) var isWorking = false
    private(set) var pendingCount = 0
    private(set) var lastSync: Date?
    private(set) var libraryRevision = 0
    /// Fetched items this app version could not apply. They remain in iCloud and
    /// are retried at the next session start.
    private(set) var quarantinedCount = 0
    let isAvailable: Bool

    @ObservationIgnored let adapter: SyncStoreAdapter
    @ObservationIgnored private let identityStore: any SyncInstallationIdentityStoring
    @ObservationIgnored private let transportFactory: @MainActor () -> any CloudSyncTransport
    @ObservationIgnored private let registerForRemoteNotifications: @MainActor () -> Void
    @ObservationIgnored private var transport: (any CloudSyncTransport)?
    @ObservationIgnored var engine: (any CloudSyncEngineSession)?
    @ObservationIgnored private(set) var engineDelegate: CloudSyncDelegate?
    @ObservationIgnored private(set) var sessionID = UUID()
    @ObservationIgnored private(set) var accountID: String?
    @ObservationIgnored private(set) var root: SyncRoot?
    @ObservationIgnored private(set) var checkpointNamespace: String?
    @ObservationIgnored var allowsSending = false
    @ObservationIgnored var hasIncomingChanges = false
    @ObservationIgnored var conflictsNeedProjection = false
    @ObservationIgnored var batchRecordLimit = 100
    @ObservationIgnored var batchByteLimit = 1_024 * 1_024
    @ObservationIgnored var inFlight: [CKRecord.ID: SyncPendingRecord] = [:]
    @ObservationIgnored var deletionsInFlight: [CKRecord.ID: String] = [:]
    /// Journal keys CloudKit rejected during this session. They are skipped so the
    /// rest of the queue keeps moving, and retried after the next session start.
    @ObservationIgnored private(set) var poisonedKeys: Set<String> = []
    @ObservationIgnored private var itemFailure: Error?
    @ObservationIgnored private var scheduledSync: Task<Void, Never>?
    @ObservationIgnored private var scheduledDeadline: Date?
    @ObservationIgnored private var needsAnotherRound = false
    @ObservationIgnored private var needsCoalescedRound = false
    /// Progress writes are batched into one upload per interval (plus pause, stop,
    /// end, and background); explicit edits still debounce briefly. Tests shorten these.
    @ObservationIgnored var coalescedSyncInterval: TimeInterval = 30
    @ObservationIgnored var journalDebounce: TimeInterval = 2
    @ObservationIgnored private var journalObserver: NSObjectProtocol?
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    @ObservationIgnored private var roundFailure: Error?
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var retryNotBefore: Date?
    @ObservationIgnored private var isForeground = true

    init(
        context: ModelContext,
        persistenceAvailable: Bool = true,
        identityStore: any SyncInstallationIdentityStoring = SyncInstallationIdentity(),
        registerForRemoteNotifications: @escaping @MainActor () -> Void = {
            UIApplication.shared.registerForRemoteNotifications()
        },
        transportFactory: @escaping @MainActor () -> any CloudSyncTransport = { PrivateCloudSyncTransport() }
    ) {
        adapter = SyncStoreAdapter(context: context)
        isAvailable = persistenceAvailable
        self.identityStore = identityStore
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.transportFactory = transportFactory
        if !persistenceAvailable {
            statusText = "Unavailable"
            detailText = CloudSyncError.persistenceUnavailable.localizedDescription
        }
        // No CKContainer, engine, account lookup, or push registration occurs
        // here. A local journal writer identity does not grant sync consent.
        journalObserver = NotificationCenter.default.addObserver(
            forName: .atlasSyncJournalDidChange, object: context, queue: .main
        ) { [weak self] notification in
            let coalesce = notification.userInfo?[atlasSyncJournalCoalesceKey] as? Bool ?? false
            Task { @MainActor [weak self] in self?.localJournalChanged(coalesce: coalesce) }
        }
    }

    isolated deinit {
        if let journalObserver { NotificationCenter.default.removeObserver(journalObserver) }
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        scheduledSync?.cancel()
    }

    /// Called once at launch. Reading the device-only consent marker is local.
    func startIfEnrolled() async {
        guard isAvailable, !isWorking, !isEnabled else { return }
        do {
            let enrollment = try adapter.enrollment()
            lastSync = enrollment.lastSyncAt
            guard enrollment.optedIn,
                let marker = try identityStore.existingIdentity(),
                marker == enrollment.consentInstallationID
            else { return }
            isEnabled = true
            await startSession(explicitConsent: false)
        } catch { present(error) }
    }

    /// The settings screen presents coverage and the ADP warning before calling.
    func enable() async {
        guard isAvailable, !isWorking else { return }
        do {
            let marker = try identityStore.identityForConsent()
            let enrollment = try adapter.enrollment()
            enrollment.consentInstallationID = marker
            enrollment.optedIn = true
            enrollment.phase = "checking"
            try adapter.saveEnrollment()
            isEnabled = true
            await startSession(explicitConsent: true)
        } catch { present(error) }
    }

    func disable() async {
        // Fence immediately, before the cancellation suspension point.
        let oldEngine = fenceSession()
        isEnabled = false
        isWorking = false
        statusText = "Off"
        detailText = "Your data stays on this device and in iCloud. Other enabled devices can continue syncing."
        do {
            let enrollment = try adapter.enrollment()
            enrollment.optedIn = false
            enrollment.phase = "off"
            try adapter.saveEnrollment()
            refreshPendingCount()
        } catch { present(error) }
        await oldEngine?.cancel()
    }

    /// Also used for a foreground transition or an opted-in silent notification.
    func sceneActive() async {
        isForeground = true
        guard isEnabled, !isWorking else { return }
        await syncNow()
    }

    /// Silent pushes can launch Atlas before SwiftUI's startup task. Validate the
    /// device-bound enrollment here too, without treating background work as a
    /// foreground transition or enabling foreground retry timers.
    func handleRemoteNotification(isForeground foreground: Bool = false) async -> Bool {
        isForeground = foreground
        if !foreground {
            scheduledSync?.cancel()
            scheduledSync = nil
        }
        let previousRevision = libraryRevision
        if isEnabled { await syncNow() } else { await startIfEnrolled() }
        return libraryRevision != previousRevision
    }

    func sceneInactive() {
        isForeground = false
        let hadPendingUpload = scheduledSync != nil
        scheduledSync?.cancel()
        scheduledSync = nil
        scheduledDeadline = nil
        // Batched progress writes must not wait out a 30 s timer that will never
        // fire in the background: start the round now while the scene winds down.
        if hadPendingUpload, isEnabled, !isWorking, engine != nil {
            Task { @MainActor [weak self] in await self?.syncNow() }
        }
    }

    func syncNow() async {
        guard isAvailable, isEnabled, !isWorking else { return }
        if let retryNotBefore, retryNotBefore > Date() {
            scheduleSync(after: retryNotBefore.timeIntervalSinceNow)
            return
        }
        if engine == nil {
            await startSession(explicitConsent: false)
            return
        }
        let token = sessionID
        isWorking = true
        defer { if token == sessionID { isWorking = false } }
        needsAnotherRound = false
        needsCoalescedRound = false
        do { try await synchronize(token: token) } catch { handleFailure(error, token: token) }
        guard token == sessionID else { return }
        let earliest = retryNotBefore?.timeIntervalSinceNow ?? 0
        if needsAnotherRound {
            // An edit journaled while this round was in flight gets its own round.
            needsAnotherRound = false
            needsCoalescedRound = false
            scheduleSync(after: max(journalDebounce, earliest))
        } else if needsCoalescedRound {
            // Progress ticks keep their batching interval instead of chaining rounds.
            needsCoalescedRound = false
            if scheduledSync == nil { scheduleSync(after: max(coalescedSyncInterval, earliest)) }
        }
    }

    func resetPersonalization() async {
        guard isAvailable else { return }
        do {
            try adapter.resetPersonalization()
            refreshPendingCount()
            if isEnabled { await syncNow() }
        } catch { present(error) }
    }

    /// Explicitly authorized by the separate destructive-action confirmation.
    /// Keeps local data and a minimal encrypted disabled marker in the control zone.
    /// True once this device has been linked to a cloud library; only then is there
    /// anything for "Delete Synced Content" to act on.
    var hasLinkedLibrary: Bool {
        guard isAvailable, let enrollment = try? adapter.enrollment() else { return false }
        return enrollment.accountID != nil && enrollment.libraryGeneration != nil
    }

    func deleteCloudContent() async {
        guard isAvailable, !isWorking else { return }
        let previousEngine = fenceSession()
        let token = sessionID
        isEnabled = false
        isWorking = true
        statusText = "Deleting iCloud Content"
        detailText = nil
        defer { if token == sessionID { isWorking = false } }
        do {
            let enrollment = try adapter.enrollment()
            guard let linkedAccount = enrollment.accountID,
                let linkedGeneration = enrollment.libraryGeneration
            else {
                throw CloudSyncError.missingEnrollment
            }
            enrollment.optedIn = false
            enrollment.phase = "deleting"
            try adapter.saveEnrollment()
            await previousEngine?.cancel()
            try checkSession(token, requireEnabled: false)
            let connection = activeTransport()
            let currentAccount = try await connection.accountID()
            try checkSession(token, requireEnabled: false)
            guard currentAccount == linkedAccount else { throw CloudSyncError.accountChanged }
            accountID = currentAccount
            let record: CKRecord
            do {
                record = try await connection.fetchRecord(CloudRecordCodec.rootRecordID)
                try checkSession(token, requireEnabled: false)
            } catch let error as CKError where Self.isMissing(error) {
                try checkSession(token, requireEnabled: false)
                throw CloudSyncError.cloudReset
            }
            var cloudRoot = try CloudRecordCodec.decodeRoot(record)
            guard cloudRoot.libraryGeneration == linkedGeneration else { throw CloudSyncError.cloudReset }
            if !cloudRoot.disabled {
                cloudRoot.disabled = true
                let marker = try CloudRecordCodec.encodeRoot(cloudRoot, reusing: record)
                _ = try await connection.saveRecordConditionally(marker)
                try checkSession(token, requireEnabled: false)
            }
            // A second account check prevents issuing the zone deletion after a switch.
            let deletionAccount = try await connection.accountID()
            try checkSession(token, requireEnabled: false)
            guard deletionAccount == linkedAccount else { throw CloudSyncError.accountChanged }
            try await connection.deleteZone(CloudRecordCodec.libraryZoneID(for: cloudRoot))
            try checkSession(token, requireEnabled: false)
            try adapter.discardTransportState()
            enrollment.phase = "deleted"
            enrollment.hasCompletedBootstrap = false
            try adapter.saveEnrollment()
            statusText = "iCloud Content Deleted"
            detailText =
                "Your local library is kept. A minimal encrypted reset marker remains in iCloud so other devices pause instead of uploading the deleted library again."
        } catch {
            handleFailure(error, token: token, requireEnabled: false)
            // The request is unfinished, not silently abandoned: the user sees a
            // deletion-specific message and can choose Delete again. Re-enabling
            // instead cleans up whatever the interrupted deletion left behind.
            guard token == sessionID, let enrollment = try? adapter.enrollment(),
                enrollment.phase == "deleting"
            else { return }
            enrollment.phase = "deleteFailed"
            try? adapter.saveEnrollment()
            if case CloudSyncError.cancelled = error { return }
            statusText = "Deletion Not Finished"
            detailText =
                "Atlas could not finish removing your synced content from iCloud. Your local library is unchanged. Check your connection and choose Delete Synced Content again; sync stays off until then."
        }
    }

    private func startSession(explicitConsent: Bool) async {
        let previousEngine = fenceSession()
        let token = sessionID
        isWorking = true
        statusText = "Checking iCloud"
        detailText = nil
        defer { if token == sessionID { isWorking = false } }
        do {
            await previousEngine?.cancel()
            try checkSession(token)
            installAccountObserver()
            let connection = activeTransport()
            let currentAccount = try await connection.accountID()
            try checkSession(token)
            let enrollment = try adapter.enrollment()
            if let previousAccount = enrollment.accountID, previousAccount != currentAccount, !explicitConsent {
                throw CloudSyncError.accountChanged
            }
            accountID = currentAccount
            let previousGeneration = enrollment.accountID == currentAccount ? enrollment.libraryGeneration : nil
            let cloudRoot = try await prepareRoot(
                connection: connection, account: currentAccount, previouslyBound: previousGeneration != nil,
                allowRecreation: explicitConsent, token: token
            )
            try checkSession(token)
            if let previousGeneration, previousGeneration != cloudRoot.libraryGeneration, !explicitConsent {
                throw CloudSyncError.cloudReset
            }
            root = cloudRoot
            let bindingChanged =
                enrollment.accountID != currentAccount || enrollment.libraryGeneration != cloudRoot.libraryGeneration
            statusText = "Preparing Merge"
            #if DEBUG
                enrollment.environment = "development"
            #else
                enrollment.environment = "production"
            #endif
            try adapter.bind(accountID: currentAccount, libraryGeneration: cloudRoot.libraryGeneration)
            // The whole-library capture is a one-time baseline per account/library
            // binding. Every later edit has an explicit journal hook, so ordinary
            // session starts skip the per-entity rescan.
            if bindingChanged || !enrollment.hasCompletedBootstrap {
                try await adapter.bootstrapLocalRecordsInBatches { try self.checkSession(token) }
                try checkSession(token)
            }
            let namespace = Self.namespace(account: currentAccount, generation: cloudRoot.libraryGeneration)
            checkpointNamespace = namespace
            // Generation maps are a local projection; an account/library rebind
            // must replay the authoritative cloud policy even if an older engine
            // checkpoint for this account still exists.
            if bindingChanged { try adapter.saveCheckpoint(nil, namespace: namespace) }
            let serialized = try adapter.loadCheckpoint(namespace: namespace)
            let state = serialized.flatMap {
                try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
            }
            if serialized != nil, state == nil { try adapter.saveCheckpoint(nil, namespace: namespace) }
            // Silent remote notifications need no alert authorization. Registration
            // is deferred until consent, account, root, and durable store are valid.
            registerForRemoteNotifications()
            let delegate = CloudSyncDelegate(coordinator: self, sessionID: token)
            engineDelegate = delegate
            engine = connection.makeEngine(serialization: state, delegate: delegate)
            try retryQuarantinedRecords(root: cloudRoot)
            try await synchronize(token: token)
            try checkSession(token)
        } catch { handleFailure(error, token: token) }
    }

    /// Items an earlier session could not apply get one more attempt per session
    /// (a newer app version or freed capacity may accept them). Unsupported
    /// protocol versions stay quarantined until the app is updated.
    private func retryQuarantinedRecords(root: SyncRoot) throws {
        for item in try adapter.quarantinedRecords() {
            do {
                let record = try CloudRecordCodec.restoreSystemFields(item.systemFields)
                record.encryptedValues[CloudRecordCodec.payloadField] = item.payload as NSData
                let envelope = try CloudRecordCodec.decode(record, root: root)
                _ = try adapter.apply(envelope, systemFields: item.systemFields, rebuildProjection: false)
                if adapter.lastApplyChangedProjection { hasIncomingChanges = true }
                try adapter.releaseQuarantine(recordName: item.recordName)
            } catch {
                continue
            }
        }
        quarantinedCount = try adapter.quarantinedCount()
    }

    private func synchronize(token: UUID) async throws {
        try checkSession(token)
        guard let engine, let root else { throw CloudSyncError.incompleteResponse }
        allowsSending = false
        roundFailure = nil
        statusText = "Syncing"
        detailText = nil
        try await validateRemoteBinding(token: token)
        try checkSession(token)
        try await engine.fetchChanges(in: CloudRecordCodec.libraryZoneID(for: root))
        try checkSession(token)
        if let roundFailure { throw roundFailure }
        try adapter.finishIncomingBatch()
        commitProjectionChanges()
        // Fetch applies generations, removals, and concurrent server values before
        // any local baseline can leave the device, including after re-enrollment.
        let enrollment = try adapter.enrollment()
        enrollment.hasCompletedBootstrap = true
        enrollment.phase = "syncing"
        try adapter.saveEnrollment()
        try await validateRemoteBinding(token: token)
        try checkSession(token)
        allowsSending = true
        try queuePendingRecords()
        do {
            try await engine.sendChanges(in: CloudRecordCodec.libraryZoneID(for: root))
        } catch {
            // Nothing in this batch was acknowledged; release the keys so the next
            // round can send them again instead of holding them until relaunch.
            inFlight.removeAll()
            deletionsInFlight.removeAll()
            throw error
        }
        try checkSession(token)
        allowsSending = false
        if conflictsNeedProjection {
            // Server copies merged during the send were applied without rebuilding
            // derived state; do that once for the whole round.
            conflictsNeedProjection = false
            try adapter.finishIncomingBatch(force: true)
        }
        commitProjectionChanges()
        if let roundFailure { throw roundFailure }
        refreshPendingCount()
        retryAttempt = 0
        retryNotBefore = nil
        lastSync = Date()
        enrollment.lastSyncAt = lastSync
        enrollment.phase = pendingCount == 0 ? "current" : "pending"
        try adapter.saveEnrollment()
        if let itemFailure {
            // Unrelated work finished; the rejected items are reported without
            // turning a per-record problem into a round failure.
            statusText = "Needs Attention"
            detailText = Self.itemFailureText(itemFailure, poisoned: poisonedKeys.count, quarantined: quarantinedCount)
        } else if quarantinedCount > 0 {
            statusText = "Needs Attention"
            detailText = Self.itemFailureText(nil, poisoned: 0, quarantined: quarantinedCount)
        } else {
            statusText = pendingCount == 0 ? "Up to Date" : "Changes Pending"
            detailText =
                pendingCount == 0
                ? "Last checked just now. Offline devices may still have changes to upload."
                : "Your local changes are saved and will sync on the next check."
        }
    }

    private static func itemFailureText(_ error: Error?, poisoned: Int, quarantined: Int) -> String {
        var parts: [String] = []
        if poisoned > 0 {
            let code = (error as? CKError).map { " (error \($0.errorCode))" } ?? ""
            parts.append(
                "\(poisoned) item\(poisoned == 1 ? "" : "s") could not be uploaded\(code) and will be retried later. Everything else synced."
            )
        }
        if quarantined > 0 {
            parts.append(
                "\(quarantined) iCloud item\(quarantined == 1 ? "" : "s") could not be applied on this device and remain in iCloud. Updating Atlas or freeing library capacity may resolve this."
            )
        }
        return parts.joined(separator: " ")
    }

    private func prepareRoot(
        connection: any CloudSyncTransport, account: String, previouslyBound: Bool,
        allowRecreation: Bool, token: UUID
    ) async throws -> SyncRoot {
        var existingRecord: CKRecord?
        do {
            existingRecord = try await connection.fetchRecord(CloudRecordCodec.rootRecordID)
            try checkSession(token)
        } catch let error as CKError where Self.isMissing(error) {
            try checkSession(token)
        }
        if let existingRecord {
            let existing = try CloudRecordCodec.decodeRoot(existingRecord)
            if !existing.disabled {
                var libraryExists = true
                do {
                    try await connection.verifyZone(CloudRecordCodec.libraryZoneID(for: existing))
                    try checkSession(token)
                } catch let error as CKError where Self.isMissing(error) {
                    try checkSession(token)
                    libraryExists = false
                }
                if libraryExists {
                    try await cleanAbandonedProvisioning(
                        connection: connection, account: account, winningRoot: existing, token: token
                    )
                    try checkSession(token)
                    return existing
                }
                // A surviving root is not proof its zone still exists. Automatic
                // startup pauses; fresh explicit consent may publish a new zone
                // using this root's existing change tag in the conditional save.
            }
            guard allowRecreation else { throw CloudSyncError.cloudReset }
            if existing.disabled {
                // A deletion that saved the disabled marker but never finished removing
                // the zone must not leave that zone orphaned behind the new generation.
                try await connection.deleteZone(CloudRecordCodec.libraryZoneID(for: existing))
                try checkSession(token)
            }
        } else if previouslyBound && !allowRecreation {
            throw CloudSyncError.cloudReset
        }

        // Persist the random candidate before touching CloudKit. A crash can leave
        // an orphan candidate, but cannot publish a root pointing to a missing zone.
        let provisioningNamespace = "provisioning|\(account)"
        let candidate: SyncRoot
        if let data = try adapter.loadCheckpoint(namespace: provisioningNamespace) {
            candidate = try JSONDecoder().decode(SyncRoot.self, from: data)
        } else {
            candidate = SyncRoot()
            try adapter.saveCheckpoint(try JSONEncoder().encode(candidate), namespace: provisioningNamespace)
        }
        try await connection.createZone(CloudRecordCodec.controlZoneID)
        try checkSession(token)
        try await connection.createZone(CloudRecordCodec.libraryZoneID(for: candidate))
        try checkSession(token)
        let verifiedAccount = try await connection.accountID()
        try checkSession(token)
        guard verifiedAccount == account else { throw CloudSyncError.accountChanged }
        do {
            let encoded = try CloudRecordCodec.encodeRoot(candidate, reusing: existingRecord)
            let saved = try await connection.saveRecordConditionally(encoded)
            try checkSession(token)
            let winner = try CloudRecordCodec.decodeRoot(saved)
            try adapter.saveCheckpoint(nil, namespace: provisioningNamespace)
            return winner
        } catch let error as CKError where error.code == .serverRecordChanged {
            try checkSession(token)
            // Conditional creation lost. The winning library/key is authoritative.
            let winningRecord = try await connection.fetchRecord(CloudRecordCodec.rootRecordID)
            try checkSession(token)
            let winner = try CloudRecordCodec.decodeRoot(winningRecord)
            guard !winner.disabled else { throw CloudSyncError.cloudReset }
            try await connection.verifyZone(CloudRecordCodec.libraryZoneID(for: winner))
            try checkSession(token)
            if winner.libraryGeneration != candidate.libraryGeneration {
                try await connection.deleteZone(CloudRecordCodec.libraryZoneID(for: candidate))
                try checkSession(token)
            }
            try adapter.saveCheckpoint(nil, namespace: provisioningNamespace)
            return winner
        }
    }

    private func cleanAbandonedProvisioning(
        connection: any CloudSyncTransport, account: String, winningRoot: SyncRoot, token: UUID
    ) async throws {
        let namespace = "provisioning|\(account)"
        guard let data = try adapter.loadCheckpoint(namespace: namespace) else { return }
        let candidate = try JSONDecoder().decode(SyncRoot.self, from: data)
        if candidate.libraryGeneration != winningRoot.libraryGeneration {
            let currentAccount = try await connection.accountID()
            try checkSession(token)
            guard currentAccount == account else { throw CloudSyncError.accountChanged }
            try await connection.deleteZone(CloudRecordCodec.libraryZoneID(for: candidate))
            try checkSession(token)
        }
        try adapter.saveCheckpoint(nil, namespace: namespace)
    }

    func validateRemoteBinding(token: UUID) async throws {
        try checkSession(token)
        guard let root, let accountID, let transport else { throw CloudSyncError.incompleteResponse }
        let currentAccount = try await transport.accountID()
        try checkSession(token)
        guard currentAccount == accountID else { throw CloudSyncError.accountChanged }
        let record: CKRecord
        do {
            record = try await transport.fetchRecord(CloudRecordCodec.rootRecordID)
            try checkSession(token)
        } catch let error as CKError where Self.isMissing(error) {
            try checkSession(token)
            throw CloudSyncError.cloudReset
        }
        let currentRoot = try CloudRecordCodec.decodeRoot(record)
        guard !currentRoot.disabled,
            currentRoot.libraryGeneration == root.libraryGeneration,
            currentRoot.identityKey == root.identityKey
        else { throw CloudSyncError.cloudReset }
    }

    private func commitProjectionChanges() {
        guard hasIncomingChanges else { return }
        libraryRevision &+= 1
        hasIncomingChanges = false
    }

    func checkSession(_ token: UUID, requireEnabled: Bool = true) throws {
        guard token == sessionID, !requireEnabled || isEnabled else { throw CloudSyncError.cancelled }
    }

    func queuePendingRecords() throws {
        guard let engine, let root, allowsSending else { return }
        let pending = try adapter.pendingRecords(
            limit: batchRecordLimit, byteLimit: batchByteLimit, excluding: poisonedKeys)
        let ids = try pending.map { try CloudRecordCodec.recordID(for: $0.envelope, root: root) }
        engine.enqueue(ids)
        let deletions = try adapter.pendingDeletions(limit: 100)
        engine.enqueueDeletions(try deletions.map { try CloudRecordCodec.recordID(for: $0.envelope, root: root) })
        engine.setUntrackedChanges(!pending.isEmpty || !deletions.isEmpty)
        refreshPendingCount()
    }

    func noteRoundFailure(_ error: Error, token: UUID) {
        guard token == sessionID else { return }
        roundFailure = error
        if let cloudError = error as? CKError, cloudError.code == .limitExceeded {
            batchRecordLimit = max(1, batchRecordLimit / 2)
            batchByteLimit = max(SyncPayload.maximumBytes, batchByteLimit / 2)
        }
        allowsSending = false
        present(error)
    }

    /// One record CloudKit rejected. The rest of the queue continues; the item is
    /// skipped for this session and reported after the round.
    func noteItemFailure(_ error: Error, key: String, token: UUID) {
        guard token == sessionID else { return }
        poisonedKeys.insert(key)
        itemFailure = error
    }

    func noteQuarantine(_ error: Error?) {
        quarantinedCount = (try? adapter.quarantinedCount()) ?? (error == nil ? quarantinedCount : quarantinedCount + 1)
    }

    func haltAfterDelegateFailure(_ error: Error, token: UUID) {
        guard token == sessionID else { return }
        // No recursive fetch/send/cancel while inside a delegate callback.
        let oldEngine = fenceSession()
        isWorking = false
        handleFailure(error, token: sessionID)
        Task { await oldEngine?.cancel() }
    }

    func refreshPendingCount() {
        do { pendingCount = try adapter.pendingCount() } catch { present(error) }
    }

    private func activeTransport() -> any CloudSyncTransport {
        if let transport { return transport }
        let created = transportFactory()
        transport = created
        return created
    }

    @discardableResult
    private func fenceSession() -> (any CloudSyncEngineSession)? {
        sessionID = UUID()
        allowsSending = false
        scheduledSync?.cancel()
        scheduledSync = nil
        let previous = engine
        engine = nil
        engineDelegate = nil
        inFlight.removeAll()
        deletionsInFlight.removeAll()
        poisonedKeys.removeAll()
        itemFailure = nil
        conflictsNeedProjection = false
        scheduledDeadline = nil
        root = nil
        accountID = nil
        checkpointNamespace = nil
        roundFailure = nil
        return previous
    }

    /// `CKAccountChanged` also fires for status changes on the same account. Only a
    /// verified different user un-enrolls the device; anything else re-validates
    /// the binding on the next round instead of discarding consent.
    private func installAccountObserver() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.accountMayHaveChanged() }
        }
    }

    func accountMayHaveChanged() async {
        guard isEnabled, let transport, let enrolledAccount = accountID else { return }
        let token = sessionID
        let currentAccount: String
        do { currentAccount = try await transport.accountID() } catch {
            // Unavailable is not "changed": pause this round, keep consent.
            guard token == sessionID else { return }
            present(error)
            return
        }
        guard token == sessionID, isEnabled else { return }
        if currentAccount == enrolledAccount {
            if !isWorking { await syncNow() }
        } else {
            haltAfterDelegateFailure(CloudSyncError.accountChanged, token: token)
        }
    }

    private func localJournalChanged(coalesce: Bool) {
        // Progress ticks are frequent; with sync off, nothing displays the count.
        if !coalesce || isEnabled { refreshPendingCount() }
        if isWorking {
            if coalesce { needsCoalescedRound = true } else { needsAnotherRound = true }
        }
        guard isEnabled, isForeground else { return }
        let earliest = retryNotBefore?.timeIntervalSinceNow ?? 0
        if coalesce {
            // Progress ticks ride along with whatever round is already scheduled;
            // otherwise they wait for the batching interval.
            let delay = max(coalescedSyncInterval, earliest)
            if let scheduledDeadline, scheduledDeadline.timeIntervalSinceNow <= delay { return }
            scheduleSync(after: delay)
        } else {
            scheduleSync(after: max(journalDebounce, earliest))
        }
    }

    private func scheduleSync(after delay: TimeInterval) {
        guard isEnabled, isForeground else { return }
        scheduledSync?.cancel()
        scheduledDeadline = Date().addingTimeInterval(delay)
        scheduledSync = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, self.isForeground else { return }
            self.scheduledSync = nil
            self.scheduledDeadline = nil
            await self.syncNow()
        }
    }

    private func scheduleRetry(for error: Error) {
        guard let error = error as? CKError else { return }
        switch error.code {
        case .limitExceeded where batchRecordLimit > 1:
            scheduleSync(after: max(2, error.retryAfterSeconds ?? 0))
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy,
            .accountTemporarilyUnavailable:
            retryAttempt = min(retryAttempt + 1, 8)
            let backoff = min(300, 5 * pow(2, Double(retryAttempt - 1)))
            let delay = max(backoff, error.retryAfterSeconds ?? 0)
            retryNotBefore = Date().addingTimeInterval(delay)
            scheduleSync(after: delay)
        default: break
        }
    }

    private func handleFailure(_ error: Error, token: UUID, requireEnabled: Bool = true) {
        guard token == sessionID else { return }
        if case CloudSyncError.cancelled = error { return }
        allowsSending = false
        present(error)
        if let cloudError = error as? CKError, cloudError.code == .changeTokenExpired {
            do {
                if let checkpointNamespace { try adapter.saveCheckpoint(nil, namespace: checkpointNamespace) }
                let previousEngine = fenceSession()
                isWorking = false
                statusText = "Preparing Merge"
                detailText =
                    "iCloud’s change history expired. Atlas is preparing a full reconciliation of your saved library."
                Task { await previousEngine?.cancel() }
                scheduleSync(after: 1)
            } catch { present(error) }
            return
        }
        if Self.requiresFreshConsent(error) {
            isEnabled = false
            do {
                let enrollment = try adapter.enrollment()
                enrollment.optedIn = false
                enrollment.phase = "attention"
                try adapter.saveEnrollment()
            } catch { detailText = error.localizedDescription }
        } else {
            scheduleRetry(for: error)
        }
    }

    private func present(_ error: Error) {
        if let cloudError = error as? CKError {
            if cloudError.userInfo[CKErrorUserDidResetEncryptedDataKey] as? Bool == true {
                statusText = "Needs Attention"
                detailText = CloudSyncError.cloudReset.localizedDescription
                return
            }
            switch cloudError.code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                statusText = "Waiting for Network"
                detailText =
                    "Your changes are saved on this device. iCloud will be checked again when Atlas is active or you choose Sync Now."
            case .quotaExceeded:
                statusText = "iCloud Storage Full"
                detailText =
                    "Free up iCloud storage to continue syncing. Your local library and pending changes are preserved."
            case .notAuthenticated, .accountTemporarilyUnavailable:
                statusText = "Account Unavailable"
                detailText = CloudSyncError.accountUnavailable.localizedDescription
            case .zoneNotFound, .unknownItem, .userDeletedZone:
                statusText = "Needs Attention"
                detailText = CloudSyncError.cloudReset.localizedDescription
            default:
                statusText = "Needs Attention"
                // Do not expose CloudKit error descriptions: these can contain IDs.
                detailText =
                    "iCloud could not complete sync (error \(cloudError.errorCode)). Your local data and pending changes are preserved."
            }
        } else {
            switch error as? CloudSyncError {
            case .accountUnavailable: statusText = "Account Unavailable"
            case .accountChanged: statusText = "Account Changed"
            default: statusText = "Needs Attention"
            }
            detailText = error.localizedDescription
        }
    }

    private static func requiresFreshConsent(_ error: Error) -> Bool {
        if let error = error as? CloudSyncError {
            switch error {
            case .accountChanged, .cloudReset, .unrecognizedDeletion: return true
            default: return false
            }
        }
        if let error = error as? CKError {
            return error.code == .zoneNotFound || error.code == .userDeletedZone
                || error.userInfo[CKErrorUserDidResetEncryptedDataKey] as? Bool == true
        }
        return false
    }

    private static func isMissing(_ error: CKError) -> Bool {
        error.code == .unknownItem || error.code == .zoneNotFound || error.code == .userDeletedZone
    }

    private static func namespace(account: String, generation: String) -> String {
        #if DEBUG
            let environment = "development"
        #else
            let environment = "production"
        #endif
        return "engine|\(environment)|\(account)|\(generation)"
    }
}
