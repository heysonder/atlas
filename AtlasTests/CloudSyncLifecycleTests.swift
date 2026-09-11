import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Atlas

@MainActor
private final class TestSyncIdentity: SyncInstallationIdentityStoring {
    var marker: String?
    var consentReads = 0
    init(marker: String? = "device-one") { self.marker = marker }
    func existingIdentity() throws -> String? { marker }
    func identityForConsent() throws -> String {
        consentReads += 1
        if let marker { return marker }
        marker = "new-device"
        return "new-device"
    }
}

@MainActor
private final class TestInstallationKeychain: SyncInstallationKeychainStoring {
    var marker: String?
    var isUnavailable = false
    func read() throws -> String? {
        if isUnavailable { throw SyncIdentityError.unavailable }
        return marker
    }
    func write(_ identity: String) throws {
        if isUnavailable { throw SyncIdentityError.unavailable }
        marker = identity
    }
}

@MainActor
private final class TestSyncEngine: CloudSyncEngineSession {
    var nativeEngine: CKSyncEngine? { nil }
    var fetchCount = 0
    var sendCount = 0
    var cancelCount = 0
    var events: [String] = []
    var queued: [CKRecord.ID] = []
    var onFetch: (() throws -> Void)?

    func fetchChanges(in zoneID: CKRecordZone.ID) async throws {
        fetchCount += 1
        events.append("fetch")
        try onFetch?()
    }
    func sendChanges(in zoneID: CKRecordZone.ID) async throws {
        sendCount += 1
        events.append("send")
    }
    func cancel() async { cancelCount += 1 }
    func enqueue(_ ids: [CKRecord.ID]) { queued.append(contentsOf: ids) }
    func remove(_ ids: [CKRecord.ID]) { queued.removeAll { ids.contains($0) } }
    func enqueueDeletions(_ ids: [CKRecord.ID]) {}
    func removeDeletions(_ ids: [CKRecord.ID]) {}
    func setUntrackedChanges(_ value: Bool) {}
}

@MainActor
private final class TestCloudTransport: CloudSyncTransport {
    var user = "account-one"
    var rootRecord: CKRecord?
    var rootMissingError = CKError(.unknownItem)
    var accountFailure: Error?
    var zoneVerificationError: Error?
    var accountContinuation: CheckedContinuation<String, Error>?
    var suspendAccountLookup = false
    var createdZones: [CKRecordZone.ID] = []
    var deletedZones: [CKRecordZone.ID] = []
    var events: [String] = []
    var conditionalSaveCount = 0
    var competingRoot: CKRecord?
    var engineCreationCount = 0
    let engine = TestSyncEngine()

    func accountID() async throws -> String {
        events.append("account")
        if let accountFailure { throw accountFailure }
        if suspendAccountLookup {
            return try await withCheckedThrowingContinuation { accountContinuation = $0 }
        }
        return user
    }
    func fetchRecord(_ id: CKRecord.ID) async throws -> CKRecord {
        events.append("root-fetch")
        guard let rootRecord else { throw rootMissingError }
        return rootRecord.copy() as! CKRecord
    }
    func saveRecordConditionally(_ record: CKRecord) async throws -> CKRecord {
        events.append("root-save")
        conditionalSaveCount += 1
        if let competingRoot {
            rootRecord = competingRoot
            self.competingRoot = nil
            throw CKError(.serverRecordChanged)
        }
        rootRecord = record
        return record
    }
    func createZone(_ id: CKRecordZone.ID) async throws {
        events.append("zone-create")
        createdZones.append(id)
    }
    func verifyZone(_ id: CKRecordZone.ID) async throws {
        events.append("zone-verify")
        if let zoneVerificationError { throw zoneVerificationError }
    }
    func deleteZone(_ id: CKRecordZone.ID) async throws {
        events.append("zone-delete")
        deletedZones.append(id)
    }
    func makeEngine(serialization: CKSyncEngine.State.Serialization?, delegate: CloudSyncDelegate)
        -> any CloudSyncEngineSession
    {
        engineCreationCount += 1
        return engine
    }
}

@Suite(.serialized)
struct CloudSyncLifecycleTests {

    @MainActor
    @Test func cloudSyncOffAndRestoredConsentNeverCreateTransport() async throws {
        let container = try makeTestContainer()
        let adapter = SyncStoreAdapter(context: container.mainContext)
        let enrollment = try adapter.enrollment()
        enrollment.optedIn = true
        enrollment.consentInstallationID = "old-device"
        try adapter.saveEnrollment()
        var creations = 0
        let identity = TestSyncIdentity(marker: "new-device")
        var registrations = 0
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: identity,
            registerForRemoteNotifications: { registrations += 1 }
        ) {
            creations += 1
            return TestCloudTransport()
        }
        await coordinator.startIfEnrolled()
        await coordinator.sceneActive()
        await coordinator.syncNow()
        _ = await coordinator.handleRemoteNotification()
        #expect(creations == 0)
        #expect(identity.consentReads == 0)
        #expect(registrations == 0)
        #expect(!coordinator.isEnabled)
    }

    @MainActor
    @Test func cloudSyncRecoveryContainerCannotEnrollOrContactCloud() async throws {
        let container = try makeTestContainer()
        var creations = 0
        let identity = TestSyncIdentity()
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, persistenceAvailable: false, identityStore: identity,
            registerForRemoteNotifications: {}
        ) {
            creations += 1
            return TestCloudTransport()
        }
        await coordinator.enable()
        await coordinator.startIfEnrolled()
        await coordinator.deleteCloudContent()
        #expect(!coordinator.isAvailable)
        #expect(!coordinator.isEnabled)
        #expect(creations == 0)
        #expect(identity.consentReads == 0)
    }

    @MainActor
    @Test func cloudSyncExistingEnrollmentDoesNotRecreateMissingRoot() async throws {
        let container = try makeTestContainer()
        let adapter = SyncStoreAdapter(context: container.mainContext)
        let enrollment = try adapter.enrollment()
        enrollment.optedIn = true
        enrollment.consentInstallationID = "device-one"
        enrollment.accountID = "account-one"
        enrollment.libraryGeneration = UUID().uuidString.lowercased()
        try adapter.saveEnrollment()
        let transport = TestCloudTransport()
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(), registerForRemoteNotifications: {}
        ) { transport }
        await coordinator.startIfEnrolled()
        #expect(!coordinator.isEnabled)
        #expect(transport.createdZones.isEmpty)
        #expect(transport.conditionalSaveCount == 0)
        #expect(transport.engineCreationCount == 0)
        #expect(!enrollment.optedIn)
    }

    @MainActor
    @Test func cloudSyncInitialProvisionCreatesZoneBeforePublishingRootAndFetchesBeforeSending() async throws {
        let container = try makeTestContainer()
        let transport = TestCloudTransport()
        var registrations = 0
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(),
            registerForRemoteNotifications: { registrations += 1 }
        ) { transport }
        await coordinator.enable()
        #expect(coordinator.isEnabled)
        #expect(registrations == 1)
        #expect(transport.createdZones.count == 2)
        let saveIndex = try #require(transport.events.firstIndex(of: "root-save"))
        let zoneIndex = try #require(transport.events.lastIndex(of: "zone-create"))
        #expect(zoneIndex < saveIndex)
        #expect(transport.engine.events == ["fetch", "send"])
        #expect(try coordinator.adapter.enrollment().hasCompletedBootstrap)
        await coordinator.disable()
    }

    @MainActor
    @Test func cloudSyncSimultaneousSetupAdoptsWinnerAndOnlyDeletesOwnCandidateZone() async throws {
        let container = try makeTestContainer()
        let transport = TestCloudTransport()
        let winningRoot = SyncRoot()
        transport.competingRoot = try CloudRecordCodec.encodeRoot(winningRoot)
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(), registerForRemoteNotifications: {}
        ) { transport }
        await coordinator.enable()
        #expect(coordinator.isEnabled)
        #expect(coordinator.root == winningRoot)
        #expect(transport.deletedZones.count == 1)
        #expect(transport.deletedZones.first != CloudRecordCodec.libraryZoneID(for: winningRoot))
        #expect(transport.deletedZones.first == transport.createdZones.last)
        await coordinator.disable()
    }

    @MainActor
    @Test func cloudSyncDisableFencesAnInFlightEnrollmentBeforeAnyUpload() async throws {
        let container = try makeTestContainer()
        let transport = TestCloudTransport()
        transport.suspendAccountLookup = true
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(), registerForRemoteNotifications: {}
        ) { transport }
        let enabling = Task { await coordinator.enable() }
        while transport.accountContinuation == nil { await Task.yield() }
        await coordinator.disable()
        transport.accountContinuation?.resume(returning: "account-one")
        transport.accountContinuation = nil
        await enabling.value
        #expect(!coordinator.isEnabled)
        #expect(!coordinator.isWorking)
        #expect(transport.createdZones.isEmpty)
        #expect(transport.conditionalSaveCount == 0)
        #expect(transport.engineCreationCount == 0)
    }

    @MainActor
    @Test func cloudSyncAccountSwitchCannotUploadRetainedLocalLibrary() async throws {
        let container = try makeTestContainer()
        let transport = TestCloudTransport()
        transport.rootRecord = try CloudRecordCodec.encodeRoot(SyncRoot())
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(), registerForRemoteNotifications: {}
        ) { transport }
        await coordinator.enable()
        let previousSends = transport.engine.sendCount
        transport.user = "account-two"
        await coordinator.syncNow()
        #expect(!coordinator.isEnabled)
        #expect(transport.engine.sendCount == previousSends)
        #expect(try coordinator.adapter.enrollment().accountID == "account-one")
    }

    @MainActor
    @Test func cloudSyncDeleteMarksRootDisabledBeforeDeletingLibraryWhileKeepingLocalData() async throws {
        let container = try makeTestContainer()
        let transport = TestCloudTransport()
        let root = SyncRoot()
        transport.rootRecord = try CloudRecordCodec.encodeRoot(root)
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(), registerForRemoteNotifications: {}
        ) { transport }
        await coordinator.enable()
        await coordinator.disable()
        transport.events.removeAll()
        await coordinator.deleteCloudContent()
        let savedRoot = try CloudRecordCodec.decodeRoot(#require(transport.rootRecord))
        #expect(savedRoot.disabled)
        let markerIndex = try #require(transport.events.firstIndex(of: "root-save"))
        let deletionIndex = try #require(transport.events.firstIndex(of: "zone-delete"))
        #expect(markerIndex < deletionIndex)
        #expect(transport.deletedZones == [CloudRecordCodec.libraryZoneID(for: root)])
        #expect(!coordinator.isEnabled)
        #expect(coordinator.statusText == "iCloud Content Deleted")
    }

    @MainActor
    @Test func cloudSyncDeleteWithoutPreviousBindingNeverCreatesTransport() async throws {
        let container = try makeTestContainer()
        var creations = 0
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(), registerForRemoteNotifications: {}
        ) {
            creations += 1
            return TestCloudTransport()
        }
        await coordinator.deleteCloudContent()
        #expect(creations == 0)
        #expect(!coordinator.isEnabled)
    }

    @MainActor
    @Test func cloudSyncFetchFailureNeverReleasesInitialUpload() async throws {
        let container = try makeTestContainer()
        let transport = TestCloudTransport()
        transport.rootRecord = try CloudRecordCodec.encodeRoot(SyncRoot())
        transport.engine.onFetch = { throw CKError(.networkUnavailable) }
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(), registerForRemoteNotifications: {}
        ) { transport }
        await coordinator.enable()
        #expect(transport.engine.sendCount == 0)
        #expect(coordinator.statusText == "Waiting for Network")
        #expect(!coordinator.allowsSending)
        #expect(!(try coordinator.adapter.enrollment().hasCompletedBootstrap))
        await coordinator.disable()
    }

    @MainActor
    @Test func cloudSyncLocalJournalCommitSchedulesUploadWithoutManualSync() async throws {
        let container = try makeTestContainer()
        let transport = TestCloudTransport()
        transport.rootRecord = try CloudRecordCodec.encodeRoot(SyncRoot())
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(), registerForRemoteNotifications: {}
        ) { transport }
        await coordinator.enable()
        // Drop startup's baseline notification, then resume an already-open session.
        coordinator.sceneInactive()
        await coordinator.sceneActive()
        let sendsBefore = transport.engine.sendCount
        SubscriptionStore.setSubscribed(
            true, channelID: "scheduled-channel", name: "A channel", avatarURL: nil,
            in: container.mainContext
        )
        let deadline = Date().addingTimeInterval(4)
        while transport.engine.sendCount == sendsBefore, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(
            transport.engine.sendCount > sendsBefore,
            "no round ran: \(coordinator.statusText) \(coordinator.detailText ?? "") working=\(coordinator.isWorking)")
        #expect(coordinator.libraryRevision == 0)
        let pending = try coordinator.adapter.pendingRecords()
        let subscription = try #require(pending.first { $0.envelope.entityID == "scheduled-channel" })
        let root = try #require(coordinator.root)
        let id = try CloudRecordCodec.recordID(for: subscription.envelope, root: root)
        #expect(transport.engine.queued.contains(id))
        await coordinator.disable()
    }

    @MainActor
    @Test func cloudSyncHonorsServerRetryAfterBeforeAnotherAttempt() async throws {
        let container = try makeTestContainer()
        let transport = TestCloudTransport()
        transport.rootRecord = try CloudRecordCodec.encodeRoot(SyncRoot())
        transport.engine.onFetch = {
            throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 60])
        }
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(), registerForRemoteNotifications: {}
        ) { transport }
        await coordinator.enable()
        await coordinator.syncNow()
        #expect(transport.engine.fetchCount == 1)
        #expect(transport.engine.sendCount == 0)
        #expect(coordinator.statusText == "Waiting for Network")
        await coordinator.disable()
    }

    @MainActor
    @Test func cloudSyncColdBackgroundPushResumesOnlyDeviceBoundEnrollment() async throws {
        let container = try makeTestContainer()
        let adapter = SyncStoreAdapter(context: container.mainContext)
        let enrollment = try adapter.enrollment()
        let root = SyncRoot()
        enrollment.optedIn = true
        enrollment.consentInstallationID = "device-one"
        enrollment.accountID = "account-one"
        enrollment.libraryGeneration = root.libraryGeneration
        try adapter.saveEnrollment()
        let transport = TestCloudTransport()
        transport.rootRecord = try CloudRecordCodec.encodeRoot(root)
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(), registerForRemoteNotifications: {}
        ) { transport }
        #expect(!coordinator.isEnabled)
        let receivedChanges = await coordinator.handleRemoteNotification()
        #expect(coordinator.isEnabled)
        #expect(transport.engine.fetchCount == 1)
        #expect(transport.engine.sendCount == 1)
        #expect(!receivedChanges)
        await coordinator.disable()
    }

    @MainActor
    @Test func cloudSyncInstallationRequiresUnbackedFileAndKeychainToMatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let markerURL = directory.appendingPathComponent("installation-id")
        let keychain = TestInstallationKeychain()
        let restoredKeychainMarker = UUID().uuidString
        keychain.marker = restoredKeychainMarker
        let identity = SyncInstallationIdentity(markerURL: markerURL, keychain: keychain)
        #expect(try identity.existingIdentity() == nil)
        let newMarker = try identity.identityForConsent()
        #expect(newMarker != restoredKeychainMarker)
        #expect(try identity.existingIdentity() == newMarker)
        let backupExcluded = try markerURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(backupExcluded == true)
        keychain.marker = UUID().uuidString
        #expect(try identity.existingIdentity() == nil)
        keychain.marker = newMarker
        try FileManager.default.removeItem(at: markerURL)
        #expect(try identity.existingIdentity() == nil)
    }

    @MainActor
    @Test func cloudSyncTemporarilyUnavailableIdentityDoesNotGrantConsent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = TestInstallationKeychain()
        let identity = SyncInstallationIdentity(
            markerURL: directory.appendingPathComponent("installation-id"), keychain: keychain)
        _ = try identity.identityForConsent()
        keychain.isUnavailable = true
        #expect(throws: SyncIdentityError.self) { try identity.existingIdentity() }
        #expect(throws: SyncIdentityError.self) { try identity.identityForConsent() }
    }

    @MainActor
    @Test func cloudSyncMissingLibraryZoneRequiresFreshConsentBeforeReplacingSurvivingRoot() async throws {
        let container = try makeTestContainer()
        let oldRoot = SyncRoot()
        let adapter = SyncStoreAdapter(context: container.mainContext)
        let enrollment = try adapter.enrollment()
        enrollment.optedIn = true
        enrollment.consentInstallationID = "device-one"
        enrollment.accountID = "account-one"
        enrollment.libraryGeneration = oldRoot.libraryGeneration
        try adapter.saveEnrollment()
        let transport = TestCloudTransport()
        transport.rootRecord = try CloudRecordCodec.encodeRoot(oldRoot)
        transport.zoneVerificationError = CKError(.zoneNotFound)
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(), registerForRemoteNotifications: {}
        ) { transport }
        await coordinator.startIfEnrolled()
        #expect(!coordinator.isEnabled)
        #expect(transport.createdZones.isEmpty)
        #expect(transport.conditionalSaveCount == 0)
        await coordinator.enable()
        #expect(coordinator.isEnabled)
        #expect(coordinator.root?.libraryGeneration != oldRoot.libraryGeneration)
        #expect(transport.createdZones.count == 2)
        #expect(transport.conditionalSaveCount == 1)
        #expect(transport.engine.events == ["fetch", "send"])
        await coordinator.disable()
    }

    @MainActor
    @Test func cloudSyncUnavailableLibraryZoneDoesNotCreateReplacementEvenWithConsent() async throws {
        let container = try makeTestContainer()
        let root = SyncRoot()
        let transport = TestCloudTransport()
        transport.rootRecord = try CloudRecordCodec.encodeRoot(root)
        transport.zoneVerificationError = CKError(.networkUnavailable)
        let coordinator = CloudSyncCoordinator(
            context: container.mainContext, identityStore: TestSyncIdentity(), registerForRemoteNotifications: {}
        ) { transport }
        await coordinator.enable()
        #expect(coordinator.statusText == "Waiting for Network")
        #expect(transport.createdZones.isEmpty)
        #expect(transport.conditionalSaveCount == 0)
        #expect(transport.engineCreationCount == 0)
        let retainedRoot = try CloudRecordCodec.decodeRoot(#require(transport.rootRecord))
        #expect(retainedRoot == root)
        await coordinator.disable()
    }

}
