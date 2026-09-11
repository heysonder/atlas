import Foundation
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func syncJournalAndCheckpointSurviveDiskReopenWhileOptedOut() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("library.store")
    var first: ModelContainer? = try AtlasContainerFactory.make(url: url)
    do {
        let context = try #require(first).mainContext
        context.autosaveEnabled = false
        try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
            context.insert(SubscribedChannel(channelID: "channel", name: "Channel"))
            try LibrarySyncJournal.capture(kind: .subscription, entityID: "channel", in: context)
        }
        let adapter = SyncStoreAdapter(context: context)
        try adapter.saveCheckpoint(Data("checkpoint".utf8), namespace: "engine")
        #expect(try adapter.enrollment().optedIn == false)
        #expect(try adapter.pendingCount() == 1)
    }
    first = nil
    let reopened = try AtlasContainerFactory.make(url: url)
    let context = reopened.mainContext
    let adapter = SyncStoreAdapter(context: context)
    #expect(try context.fetchCount(FetchDescriptor<SubscribedChannel>()) == 1)
    #expect(try adapter.pendingRecords().first?.envelope.entityID == "channel")
    #expect(try adapter.loadCheckpoint(namespace: "engine") == Data("checkpoint".utf8))
    #expect(try adapter.enrollment().optedIn == false)
}

@MainActor
@Test func oldUploadAcknowledgmentCannotDiscardNewerLocalRevision() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let adapter = SyncStoreAdapter(context: context)
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        context.insert(SubscribedChannel(channelID: "channel", name: "Before"))
        try LibrarySyncJournal.capture(kind: .subscription, entityID: "channel", in: context)
    }
    let sent = try #require(adapter.pendingRecords().first)
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        let row = try #require(context.fetch(FetchDescriptor<SubscribedChannel>()).first)
        row.name = "After"
        try LibrarySyncJournal.capture(kind: .subscription, entityID: "channel", in: context)
    }
    try adapter.acknowledge(key: sent.key, revision: sent.revision, systemFields: Data("system".utf8))
    let pending = try #require(adapter.pendingRecords().first)
    #expect(pending.revision > sent.revision)
    #expect(pending.systemFields == Data("system".utf8))
    let data = try #require(pending.envelope.effectivePayload)
    #expect(try SyncPayload.decode(SyncSubscriptionPayload.self, from: data).name == "After")
    try adapter.acknowledge(key: pending.key, revision: pending.revision, systemFields: nil)
    #expect(try adapter.pendingCount() == 0)
}

@MainActor
@Test func remoteReplayDoesNotProduceAnEchoAndInvalidPayloadDoesNotAdvanceLocalState() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let adapter = SyncStoreAdapter(context: context)
    let data = try SyncPayload.encode(
        SyncSubscriptionPayload(channelID: "channel", name: "Remote", avatarURL: nil, subscribedAt: .now))
    let envelope = try SyncEnvelope.mutation(
        kind: .subscription, entityID: "channel", payload: data, writerID: "remote", counter: 1)
    try adapter.apply(envelope)
    try adapter.apply(envelope)
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        try LibrarySyncJournal.capture(kind: .subscription, entityID: "channel", in: context)
    }
    #expect(try adapter.pendingCount() == 0)
    #expect(try context.fetchCount(FetchDescriptor<SubscribedChannel>()) == 1)
    let invalidData = try SyncPayload.encode(
        SyncSubscriptionPayload(channelID: "different-id", name: "Invalid", avatarURL: nil, subscribedAt: .now))
    let invalid = try SyncEnvelope.mutation(
        kind: .subscription, entityID: "channel", from: envelope, payload: invalidData, writerID: "remote", counter: 2)
    #expect(throws: (any Error).self) { try adapter.apply(invalid) }
    #expect(try context.fetch(FetchDescriptor<SubscribedChannel>()).first?.name == "Remote")
    #expect(try adapter.state(kind: .subscription, entityID: "channel")?.envelopeData == SyncPayload.encode(envelope))
}

@MainActor
@Test func explicitRemovalKeepsTombstoneAndSnapshotAbsenceDoesNotDeleteStagedMembership() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let adapter = SyncStoreAdapter(context: context)
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        context.insert(SubscribedChannel(channelID: "channel", name: "Local"))
        try LibrarySyncJournal.capture(kind: .subscription, entityID: "channel", in: context)
    }
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        try LibrarySyncJournal.record(kind: .subscription, entityID: "channel", payload: nil, in: context)
        for row in try context.fetch(FetchDescriptor<SubscribedChannel>()) { context.delete(row) }
    }
    #expect(try adapter.pendingRecords().first?.envelope.isTombstone == true)

    let playlistID = UUID()
    let memberID = LibrarySyncJournal.playlistVideoIdentity(playlistID: playlistID, videoID: "video:with:colons")
    let payload = try SyncPayload.encode(
        SyncPlaylistVideoPayload(
            playlistID: playlistID, parentIncarnation: nil, videoID: "video:with:colons", title: "Staged",
            uploader: nil, thumbnailURL: nil, duration: 12, addedAt: .now))
    let member = try SyncEnvelope.mutation(
        kind: .playlistVideo, entityID: memberID, payload: payload, writerID: "remote", counter: 1)
    try adapter.apply(member)
    try LibrarySyncJournal.transaction(in: context) {}
    let state = try #require(try adapter.state(kind: .playlistVideo, entityID: memberID))
    #expect(state.isMaterialized == false)
    #expect(try SyncPayload.decode(SyncEnvelope.self, from: state.envelopeData).isTombstone == false)
    #expect(try context.fetchCount(FetchDescriptor<PlaylistVideo>()) == 0)
}

@MainActor
@Test func clearQueuesPhysicalCleanupAndAlwaysPrioritizesItsBarrier() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let adapter = SyncStoreAdapter(context: context)
    // Physical cloud cleanup only exists for a library bound to an account.
    try adapter.bind(accountID: "account", libraryGeneration: "library")
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        for index in 0..<110 {
            let id = "channel-\(index)"
            context.insert(SubscribedChannel(channelID: id, name: id))
            try LibrarySyncJournal.capture(kind: .subscription, entityID: id, in: context)
        }
        context.insert(HistoryEntry(videoID: "video", title: "Before clear"))
        try LibrarySyncJournal.capture(kind: .history, entityID: "video", in: context)
    }
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        try LibrarySyncJournal.clear(kind: .history, in: context)
    }
    #expect(try adapter.pendingRecords().first?.envelope.kind == .policy)
    #expect(try adapter.pendingRecords(limit: 0).isEmpty)
    #expect(try adapter.pendingRecords(byteLimit: 0).isEmpty)
    #expect(try adapter.pendingDeletions(limit: 0).isEmpty)
    let deletion = try #require(adapter.pendingDeletions().first)
    #expect(deletion.envelope.kind == .history)
    #expect(deletion.envelope.isTombstone)
    #expect(deletion.envelope.effectivePayload == nil)
    #expect(try context.fetchCount(FetchDescriptor<HistoryEntry>()) == 0)
    let before = try adapter.pendingCount()
    try adapter.acknowledgeDeletion(key: deletion.key)
    #expect(try adapter.pendingCount() == before - 1)
}

@MainActor
@Test func journalWriterResumesAbovePriorCausalCounterAfterEnrollmentCounterReset() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let adapter = SyncStoreAdapter(context: context)
    let enrollment = try adapter.enrollment()
    let writer = enrollment.installationID
    let data = try SyncPayload.encode(
        SyncSubscriptionPayload(channelID: "channel", name: "Before", avatarURL: nil, subscribedAt: .now))
    let prior = try SyncEnvelope.mutation(
        kind: .subscription, entityID: "channel", payload: data, writerID: writer, counter: 10_000)
    try adapter.apply(prior)
    enrollment.counter = 0
    try context.save()
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        let row = try #require(context.fetch(FetchDescriptor<SubscribedChannel>()).first)
        row.name = "After"
        try LibrarySyncJournal.capture(kind: .subscription, entityID: "channel", in: context)
    }
    let outgoing = try #require(adapter.pendingRecords().first?.envelope)
    #expect((outgoing.register.context.counters[writer] ?? 0) > 10_000)
    #expect(
        try SyncPayload.decode(SyncSubscriptionPayload.self, from: #require(outgoing.effectivePayload)).name == "After")
}

@MainActor
@Test func throwingMutationRollsBackModelAndJournalTogether() throws {
    enum Failure: Error { case injected }
    let container = try makeTestContainer()
    let context = container.mainContext
    let adapter = SyncStoreAdapter(context: context)
    #expect(throws: Failure.self) {
        try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
            context.insert(SubscribedChannel(channelID: "channel", name: "Uncommitted"))
            try LibrarySyncJournal.capture(kind: .subscription, entityID: "channel", in: context)
            throw Failure.injected
        }
    }
    let reader = ModelContext(container)
    #expect(try reader.fetchCount(FetchDescriptor<SubscribedChannel>()) == 0)
    #expect(try reader.fetchCount(FetchDescriptor<SyncRecordState>()) == 0)
    #expect(try adapter.pendingCount() == 0)
}

@MainActor
@Test func returningToAnAccountRestoresItsCategoryGenerationBeforeBootstrap() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let adapter = SyncStoreAdapter(context: context)
    try adapter.bind(accountID: "account-a", libraryGeneration: "library-a")
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        try LibrarySyncJournal.clear(kind: .history, in: context)
    }
    let generationA = try adapter.generation(for: .history)
    try adapter.bind(accountID: "account-b", libraryGeneration: "library-b")
    #expect(try adapter.generation(for: .history) == "initial")
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        try LibrarySyncJournal.clear(kind: .search, in: context)
    }
    let generationB = try adapter.generation(for: .search)
    try adapter.bind(accountID: "account-a", libraryGeneration: "library-a")
    #expect(try adapter.generation(for: .history) == generationA)
    #expect(try adapter.generation(for: .search) == "initial")
    try adapter.bind(accountID: "account-b", libraryGeneration: "library-b")
    #expect(try adapter.generation(for: .search) == generationB)
}

@MainActor
@Test func staleContextSearchIncrementUsesFreshComponentAndCausalCounter() throws {
    let container = try makeTestContainer()
    let first = container.mainContext
    let second = ModelContext(container)
    first.autosaveEnabled = false
    second.autosaveEnabled = false
    #expect(SearchHistoryStore.record("query", in: first)?.count == 1)
    let stale = try #require(second.fetch(FetchDescriptor<SearchEntry>()).first)
    let staleAdapter = SyncStoreAdapter(context: second)
    _ = try staleAdapter.enrollment()
    _ = try staleAdapter.state(kind: .search, entityID: "query")
    #expect(SearchHistoryStore.record("query", in: first)?.count == 2)
    #expect(stale.count == 1)
    #expect(SearchHistoryStore.record("query", in: second)?.count == 3)
    let reader = ModelContext(container)
    #expect(try reader.fetch(FetchDescriptor<SearchEntry>()).first?.count == 3)
    let state = try #require(try SyncStoreAdapter(context: reader).state(kind: .search, entityID: "query"))
    try SyncPayload.decode(SyncEnvelope.self, from: state.envelopeData).validate()
}

@MainActor
@Test func thousandItemBootstrapCommitsOneCoalescedDurableJournal() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    context.autosaveEnabled = false
    for index in 0..<1_000 {
        context.insert(SubscribedChannel(channelID: "batch-\(index)", name: "Channel \(index)"))
    }
    try context.save()
    let start = Date()
    let adapter = SyncStoreAdapter(context: context)
    try adapter.bootstrapLocalRecords()
    let elapsed = Date().timeIntervalSince(start)
    #expect(try adapter.pendingCount() == 1_001)
    #expect(try context.fetchCount(FetchDescriptor<SubscribedChannel>()) == 1_000)
    print("Atlas sync 1,000-item bootstrap: \(elapsed) seconds")
    try LibrarySyncJournal.transaction(in: context) {}
    #expect(try adapter.pendingCount() == 1_001)
}

@MainActor
@Test func ownCloudEchoOnlyUpdatesTransportMetadataAndDeadParentChildrenQueueCleanup() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let adapter = SyncStoreAdapter(context: context)
    try adapter.bind(accountID: "account", libraryGeneration: "library")
    let parentID = UUID()
    let parentPayload = try SyncPayload.encode(
        SyncPlaylistPayload(
            id: parentID, name: "Playlist", createdAt: .now, systemKind: nil, legacyIDs: nil, syncIncarnation: nil))
    let parent = try SyncEnvelope.mutation(
        kind: .playlist, entityID: parentID.uuidString.lowercased(), payload: parentPayload, writerID: "remote",
        counter: 1)
    try adapter.apply(parent)
    #expect(adapter.lastApplyChangedProjection)
    try adapter.apply(parent, systemFields: Data("server-metadata".utf8))
    #expect(adapter.lastApplyChangedProjection == false)
    let deletion = try SyncEnvelope.mutation(
        kind: .playlist, entityID: parent.entityID, from: parent, payload: nil, writerID: "remote", counter: 2)
    try adapter.apply(deletion)
    #expect(adapter.lastApplyChangedProjection)
    let childID = LibrarySyncJournal.playlistVideoIdentity(playlistID: parentID, videoID: "late-child")
    let payload = try SyncPayload.encode(
        SyncPlaylistVideoPayload(
            playlistID: parentID, parentIncarnation: nil, videoID: "late-child", title: "Offline child", uploader: nil,
            thumbnailURL: nil, duration: 12, addedAt: .now))
    let child = try SyncEnvelope.mutation(
        kind: .playlistVideo, entityID: childID, payload: payload, writerID: "offline", counter: 1)
    try adapter.apply(child)
    #expect(adapter.lastApplyChangedProjection == false)
    #expect(try context.fetchCount(FetchDescriptor<PlaylistVideo>()) == 0)
    let cleanup = try #require(adapter.pendingDeletions().first)
    #expect(cleanup.envelope.entityID == childID)
    #expect(cleanup.envelope.isTombstone)
    #expect(cleanup.envelope.effectivePayload == nil)
}

@MainActor
@Test func interruptedBatchedBootstrapResumesWithoutLosingCommittedOrConcurrentEdits() async throws {
    enum Stop: Error { case cancelled }
    let container = try makeTestContainer()
    let context = container.mainContext
    context.autosaveEnabled = false
    for index in 0..<210 {
        context.insert(SubscribedChannel(channelID: "resume-\(index)", name: "Before"))
    }
    try context.save()
    let adapter = SyncStoreAdapter(context: context)
    var checks = 0
    do {
        try await adapter.bootstrapLocalRecordsInBatches {
            checks += 1
            if checks == 3 { throw Stop.cancelled }
        }
        Issue.record("Expected cancellation after the first durable batch")
    } catch Stop.cancelled {}
    #expect(try adapter.pendingCount() == 100)
    var remainingID: String?
    for row in try context.fetch(FetchDescriptor<SubscribedChannel>()) {
        if try adapter.state(kind: .subscription, entityID: row.channelID) == nil {
            remainingID = row.channelID
            break
        }
    }
    let deletedID = try #require(remainingID)
    let editedID = try #require(adapter.pendingRecords().first?.envelope.entityID)
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        try LibrarySyncJournal.record(kind: .subscription, entityID: deletedID, payload: nil, in: context)
        for row in try context.fetch(
            FetchDescriptor<SubscribedChannel>(predicate: #Predicate { $0.channelID == deletedID }))
        { context.delete(row) }
    }
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        let id = editedID
        let row = try #require(
            context.fetch(FetchDescriptor<SubscribedChannel>(predicate: #Predicate { $0.channelID == id })).first)
        row.name = "Edited while bootstrap was interrupted"
        try LibrarySyncJournal.capture(kind: .subscription, entityID: id, in: context)
    }
    try await adapter.bootstrapLocalRecordsInBatches {}
    #expect(try adapter.pendingCount() == 211)
    let record = try #require(try adapter.state(kind: .subscription, entityID: editedID))
    let payload = try #require(SyncPayload.decode(SyncEnvelope.self, from: record.envelopeData).effectivePayload)
    #expect(
        try SyncPayload.decode(SyncSubscriptionPayload.self, from: payload).name
            == "Edited while bootstrap was interrupted")
    let deletedState = try #require(try adapter.state(kind: .subscription, entityID: deletedID))
    #expect(try SyncPayload.decode(SyncEnvelope.self, from: deletedState.envelopeData).isTombstone)
    #expect(try context.fetchCount(FetchDescriptor<SubscribedChannel>()) == 209)
}

@MainActor
@Test func aNewWriterIdentityStillUploadsEditsToAcknowledgedRecords() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let adapter = SyncStoreAdapter(context: context)
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        context.insert(SubscribedChannel(channelID: "channel", name: "Before"))
        try LibrarySyncJournal.capture(kind: .subscription, entityID: "channel", in: context)
    }
    let sent = try #require(adapter.pendingRecords().first)
    try adapter.acknowledge(key: sent.key, revision: sent.revision, systemFields: Data("tag".utf8))
    #expect(try adapter.pendingCount() == 0)
    // A restore from backup mints a new device writer: the enrollment row is
    // re-stamped and its counter restarts at zero on the next enrollment read.
    let enrollment = try adapter.enrollment()
    enrollment.installationID = "restored-writer:" + enrollment.replicaID
    enrollment.counter = 0
    try context.save()
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        let row = try #require(context.fetch(FetchDescriptor<SubscribedChannel>()).first)
        row.name = "After"
        try LibrarySyncJournal.capture(kind: .subscription, entityID: "channel", in: context)
    }
    let fresh = SyncStoreAdapter(context: context)
    #expect(try fresh.pendingCount() == 1)
    let outgoing = try #require(fresh.pendingRecords().first)
    #expect(outgoing.revision > sent.revision)
    #expect(
        try SyncPayload.decode(SyncSubscriptionPayload.self, from: #require(outgoing.envelope.effectivePayload)).name
            == "After")
}

@MainActor
@Test func aRejectedIncomingRecordDoesNotDiscardUnrelatedPendingEdits() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let adapter = SyncStoreAdapter(context: context)
    // An autosave-only insert, as a finished download leaves behind.
    context.insert(SubscribedChannel(channelID: "unsaved", name: "Pending"))
    // Well-formed transport, but the payload describes a different channel.
    let mismatched = try SyncEnvelope.mutation(
        kind: .subscription, entityID: "channel",
        payload: SyncPayload.encode(
            SyncSubscriptionPayload(channelID: "other", name: "Other", avatarURL: nil, subscribedAt: .now)),
        writerID: "remote:1", counter: 1)
    #expect(throws: SyncStorageError.invalidPayload) { try adapter.apply(mismatched) }
    let reader = ModelContext(container)
    #expect(
        try reader.fetchCount(FetchDescriptor<SubscribedChannel>(predicate: #Predicate { $0.channelID == "unsaved" }))
            == 1)
}

@MainActor
@Test func anUnboundLibraryDropsRetiredRowsAndAFullJournalCompactsBeforeRefusing() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let adapter = SyncStoreAdapter(context: context)
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        for index in 0..<5 {
            context.insert(HistoryEntry(videoID: "video-\(index)", title: "Video \(index)"))
            try LibrarySyncJournal.capture(kind: .history, entityID: "video-\(index)", in: context)
        }
    }
    #expect(try context.fetchCount(FetchDescriptor<SyncRecordState>()) == 5)
    // Sync was never enabled: there is no cloud copy to delete, so a clear leaves
    // only its barrier behind instead of five pending deletions.
    #expect(PlaybackHistoryStore.clear(in: context))
    #expect(try adapter.pendingDeletions().isEmpty)
    #expect(try context.fetchCount(FetchDescriptor<SyncRecordState>()) == 1)

    // A bound library keeps its deletions until CloudKit confirms them, but rows
    // CloudKit never saw are compacted away once the journal is full.
    try adapter.bind(accountID: "account", libraryGeneration: "library")
    try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
        for index in 0..<5 {
            context.insert(HistoryEntry(videoID: "bound-\(index)", title: "Video \(index)"))
            try LibrarySyncJournal.capture(kind: .history, entityID: "bound-\(index)", in: context)
        }
    }
    #expect(PlaybackHistoryStore.clear(in: context))
    #expect(try adapter.pendingDeletions().count == 5)
    let previousMaximum = SyncStoreAdapter.maximumJournalRecords
    defer { SyncStoreAdapter.maximumJournalRecords = previousMaximum }
    SyncStoreAdapter.maximumJournalRecords = try context.fetchCount(FetchDescriptor<SyncRecordState>())
    #expect(
        SubscriptionStore.setSubscribed(
            true, channelID: "after-compaction", name: "Channel", avatarURL: nil, in: context))
    #expect(try adapter.pendingDeletions().isEmpty)
    #expect(try SyncStoreAdapter(context: context).state(kind: .subscription, entityID: "after-compaction") != nil)
}
