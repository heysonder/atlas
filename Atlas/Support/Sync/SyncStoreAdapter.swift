import Foundation
import SwiftData

extension Notification.Name {
    static let atlasSyncJournalDidChange = Notification.Name("atlasSyncJournalDidChange")
}

/// User-info key on `atlasSyncJournalDidChange`. `true` marks a high-frequency
/// progress write that the coordinator may batch into a later upload.
nonisolated let atlasSyncJournalCoalesceKey = "coalesce"

nonisolated enum SyncStorageError: Error, Equatable {
    case invalidPayload
    case unsupportedKind
    case capacityExceeded(String)
    case revisionExhausted
    case wrongGeneration
}

nonisolated struct SyncPendingRecord: Sendable {
    let key: String
    let envelope: SyncEnvelope
    let revision: Int64
    let systemFields: Data?
}

nonisolated struct SyncSubscriptionPayload: Codable, Sendable {
    var channelID: String
    var name: String
    var avatarURL: String?
    var subscribedAt: Date
}

nonisolated struct SyncHistoryPayload: Codable, Sendable {
    var videoID: String
    var title: String
    var uploader: String?
    var thumbnailURL: String?
    var watchedAt: Date
    var positionSeconds: Double
    var durationSeconds: Double
    var playbackSessionID: String?
    var playbackSessionStartedAt: Date?
    var playbackSequence: Int

    static func mergedPayloads(_ payloads: [Data]) throws -> Data {
        let values = try payloads.map { try SyncPayload.decode(Self.self, from: $0) }
        var starts: [String: Date] = [:]
        for value in values {
            if let session = value.playbackSessionID, let start = value.playbackSessionStartedAt {
                if let observed = starts[session], observed != start { throw SyncStorageError.invalidPayload }
                starts[session] = start
            }
        }
        let encoded = try values.map { (value: $0, data: try SyncPayload.encode($0)) }
        guard
            let winner = encoded.max(by: { left, right in
                let lhs = left.value
                let rhs = right.value
                let leftStart = lhs.playbackSessionStartedAt ?? lhs.watchedAt
                let rightStart = rhs.playbackSessionStartedAt ?? rhs.watchedAt
                if leftStart != rightStart { return leftStart < rightStart }
                if lhs.playbackSessionID != rhs.playbackSessionID {
                    return (lhs.playbackSessionID ?? "") < (rhs.playbackSessionID ?? "")
                }
                if lhs.playbackSequence != rhs.playbackSequence { return lhs.playbackSequence < rhs.playbackSequence }
                if lhs.watchedAt != rhs.watchedAt { return lhs.watchedAt < rhs.watchedAt }
                return left.data.lexicographicallyPrecedes(right.data)
            })
        else { throw SyncStorageError.invalidPayload }
        return winner.data
    }
}

nonisolated struct SyncPlaylistPayload: Codable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var systemKind: String?
    var legacyIDs: [UUID]?
    var syncIncarnation: String?
}

nonisolated struct SyncPlaylistVideoPayload: Codable, Sendable {
    var playlistID: UUID
    var parentIncarnation: String?
    var videoID: String
    var title: String
    var uploader: String?
    var thumbnailURL: String?
    var duration: Int
    var addedAt: Date
}

nonisolated struct SyncFeedbackPayload: Codable, Sendable {
    var videoID: String
    var signal: Int
    var title: String
    var uploader: String?
    var category: String?
    var tags: [String]?
    var createdAt: Date
}

nonisolated struct SyncSearchPayload: Codable, Sendable {
    var query: String
    var displayQuery: String?
    var lastSearchedAt: Date
    var legacyCount: Int
    var components: [String: Int]

    var count: Int {
        components.values.reduce(min(max(legacyCount, 0), 1_000_000)) {
            min($0 + min(max($1, 0), 1_000_000), 1_000_000)
        }
    }

    static func mergedPayloads(_ payloads: [Data]) throws -> Data {
        let values = try payloads.map { try SyncPayload.decode(Self.self, from: $0) }
        let encoded = try values.map { (value: $0, data: try SyncPayload.encode($0)) }
        guard
            var result = encoded.max(by: {
                if $0.value.lastSearchedAt != $1.value.lastSearchedAt {
                    return $0.value.lastSearchedAt < $1.value.lastSearchedAt
                }
                return $0.data.lexicographicallyPrecedes($1.data)
            })?.value
        else { throw SyncStorageError.invalidPayload }
        for value in values {
            guard value.query == result.query, value.components.count <= 128,
                (0...1_000_000).contains(value.legacyCount),
                value.components.values.allSatisfy({ (0...1_000_000).contains($0) })
            else { throw SyncStorageError.invalidPayload }
            result.legacyCount = max(result.legacyCount, value.legacyCount)
            for (writer, count) in value.components {
                result.components[writer] = max(result.components[writer] ?? 0, count)
            }
        }
        guard result.components.count <= 128 else { throw SyncStorageError.capacityExceeded("search writers") }
        return try SyncPayload.encode(result)
    }
}

nonisolated struct SyncPreferencePayload: Codable, Sendable {
    var key: String
    var value: String
    var modifiedAt: Date
    /// `false` marks an unedited migration baseline (a pre-sync default). Absent
    /// in payloads written before this field existed; those count as explicit.
    var isExplicit: Bool?
}

nonisolated struct SyncNamespacePolicy: Codable, Sendable {
    var generations: Data
    var retiredGenerations: Data
}

nonisolated struct SyncCategoryPolicy: Codable, Sendable {
    var kind: SyncKind
    var generation: String
}

/// Every caller is isolated to the model context's owner. No networking happens here,
/// including when a user has never enabled sync.
@MainActor
enum LibrarySyncJournal {
    private static var transactionDepth: [ObjectIdentifier: Int] = [:]
    private static var remoteDepth: [ObjectIdentifier: Int] = [:]
    private static var activeAdapters: [ObjectIdentifier: SyncStoreAdapter] = [:]

    private static func adapter(in context: ModelContext) -> SyncStoreAdapter {
        activeAdapters[ObjectIdentifier(context)] ?? SyncStoreAdapter(context: context)
    }

    static func playlistVideoIdentity(playlistID: UUID, videoID: String, incarnation: String? = nil) -> String {
        playlistID.uuidString.lowercased() + ":" + (incarnation ?? "initial") + ":" + videoID
    }

    static func capture(kind: SyncKind, entityID: String, in context: ModelContext) throws {
        guard remoteDepth[ObjectIdentifier(context), default: 0] == 0 else { return }
        try adapter(in: context).capture(kind: kind, entityID: entityID)
    }

    static func captureSearch(query: String, isNew: Bool, in context: ModelContext) throws {
        let adapter = adapter(in: context)
        if isNew {
            guard
                let row = try context.fetch(FetchDescriptor<SearchEntry>(predicate: #Predicate { $0.query == query }))
                    .first
            else { return }
            let payload = SyncSearchPayload(
                query: query, displayQuery: row.displayQuery, lastSearchedAt: row.lastSearchedAt, legacyCount: 0,
                components: [try adapter.enrollment().installationID: row.count])
            try record(kind: .search, entityID: query, payload: SyncPayload.encode(payload), in: context)
        } else {
            try capture(kind: .search, entityID: query, in: context)
        }
    }

    static func flushPendingChanges(in context: ModelContext) throws {
        try captureLocalChanges(in: context)
        try context.save()
        postJournalChange(coalesce: false, in: context)
    }

    static func hasRecord(kind: SyncKind, entityID: String, in context: ModelContext) throws -> Bool {
        try adapter(in: context).state(kind: kind, entityID: entityID) != nil
    }

    /// Posted with the context as the sender so only the coordinator watching that
    /// store wakes up, not every coordinator in the process.
    private static func postJournalChange(coalesce: Bool, in context: ModelContext) {
        NotificationCenter.default.post(
            name: .atlasSyncJournalDidChange, object: context,
            userInfo: [atlasSyncJournalCoalesceKey: coalesce])
    }

    /// `coalesceSync` marks a progress write: the coordinator batches those into a
    /// periodic upload instead of starting a CloudKit round after each one.
    static func transaction(
        in context: ModelContext, captureChanges: Bool = true, notifySync: Bool = true,
        coalesceSync: Bool = false, _ mutation: () throws -> Void
    ) throws {
        let id = ObjectIdentifier(context)
        let outermost = transactionDepth[id, default: 0] == 0
        if outermost {
            // Unrelated autosaved edits (a download row, a cache entry) must not be
            // discarded by this transaction's rollback. Commit them on their own first.
            if context.hasChanges { try context.save() }
            activeAdapters[id] = SyncStoreAdapter(context: context)
        }
        transactionDepth[id, default: 0] += 1
        defer {
            transactionDepth[id, default: 1] -= 1
            if transactionDepth[id] == 0 {
                transactionDepth.removeValue(forKey: id)
                activeAdapters.removeValue(forKey: id)
            }
        }
        do {
            try mutation()
            if outermost {
                if captureChanges { try captureLocalChanges(in: context) }
                try context.save()
                if notifySync { postJournalChange(coalesce: coalesceSync, in: context) }
            }
        } catch {
            if outermost { context.rollback() }
            throw error
        }
    }

    static func record(kind: SyncKind, entityID: String, payload: Data?, in context: ModelContext) throws {
        guard remoteDepth[ObjectIdentifier(context), default: 0] == 0 else { return }
        let adapter = adapter(in: context)
        try adapter.recordLocal(kind: kind, entityID: entityID, payload: payload)
    }

    static func captureLocalChanges(in context: ModelContext) throws {
        guard remoteDepth[ObjectIdentifier(context), default: 0] == 0 else { return }
        try adapter(in: context).captureLocalChanges()
    }

    static func clear(kind: SyncKind, in context: ModelContext) throws {
        try adapter(in: context).clear(kind: kind)
    }

    /// Retention expiry: the cloud record becomes a pending physical deletion and the
    /// journal row disappears once CloudKit confirms. No causal tombstone is written.
    static func retire(kind: SyncKind, entityID: String, in context: ModelContext) throws {
        guard remoteDepth[ObjectIdentifier(context), default: 0] == 0 else { return }
        try adapter(in: context).retire(kind: kind, entityID: entityID)
    }

    static func historySessionMarker(videoID: String, in context: ModelContext) throws -> String {
        let adapter = SyncStoreAdapter(context: context)
        return try adapter.generation(for: .history) + ":"
            + (adapter.state(kind: .history, entityID: videoID)?.deletionMarker ?? "initial")
    }

    fileprivate static func remote<T>(in context: ModelContext, _ operation: () throws -> T) rethrows -> T {
        let id = ObjectIdentifier(context)
        remoteDepth[id, default: 0] += 1
        defer {
            remoteDepth[id, default: 1] -= 1
            if remoteDepth[id] == 0 { remoteDepth.removeValue(forKey: id) }
        }
        return try operation()
    }
}

@MainActor
final class SyncStoreAdapter {
    let context: ModelContext
    static var maximumJournalRecords = 250_000
    private static let maximumCheckpointBytes = 16 * 1_024 * 1_024
    private static var allocatedRevisions: [String: Int64] = [:]

    private let deviceWriterID = SyncInstallationIdentity.writerIdentity()
    private var diskReadContext: ModelContext?
    private var diskEnrollment: SyncEnrollment?
    private var didReadDiskEnrollment = false
    private var cachedEnrollment: SyncEnrollment?
    private var cachedJournalCount: Int?
    private var rebuildActivityProjection = true
    private var appliedSinceLastFinish = false
    private(set) var lastApplyChangedProjection = false

    init(context: ModelContext) { self.context = context }

    private func freshReadContext() -> ModelContext {
        if let diskReadContext { return diskReadContext }
        let reader = ModelContext(context.container)
        reader.autosaveEnabled = false
        diskReadContext = reader
        return reader
    }

    /// One fetch per adapter (adapters are per transaction or per coordinator session).
    /// A temporarily unreadable device identity keeps the persisted writer instead of
    /// introducing a throwaway writer whose counters would restart from zero.
    func enrollment() throws -> SyncEnrollment {
        if let cachedEnrollment, !cachedEnrollment.isDeleted, cachedEnrollment.modelContext === context {
            return cachedEnrollment
        }
        if let row = try context.fetch(FetchDescriptor<SyncEnrollment>()).first {
            if let deviceWriterID {
                let writer = deviceWriterID + ":" + row.replicaID
                if row.installationID != writer {
                    row.installationID = writer
                    row.counter = 0
                }
            }
            cachedEnrollment = row
            return row
        }
        let row = SyncEnrollment()
        row.installationID = (deviceWriterID ?? UUID().uuidString) + ":" + row.replicaID
        context.insert(row)
        cachedEnrollment = row
        return row
    }

    func saveEnrollment() throws { try save() }

    func bind(accountID: String, libraryGeneration: String) throws {
        try PersistedMetadataPolicy.requireIdentifier(accountID, field: "sync.account")
        try PersistedMetadataPolicy.requireIdentifier(libraryGeneration, field: "sync.library")
        let row = try enrollment()
        let changed = row.accountID != accountID || row.libraryGeneration != libraryGeneration
        if changed {
            let oldNamespace = try currentNamespace()
            let key = oldNamespace + ":category-policy"
            let data = try SyncPayload.encode(
                SyncNamespacePolicy(generations: row.generationsData, retiredGenerations: row.retiredGenerationsData))
            if let stored = try context.fetch(
                FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.namespace == key })
            ).first {
                stored.data = data
            } else {
                context.insert(SyncCheckpoint(namespace: key, data: data))
            }
            row.hasCompletedBootstrap = false
        }
        let hadAccount = row.accountID != nil
        row.accountID = accountID
        row.libraryGeneration = libraryGeneration
        let namespace = try currentNamespace()
        if changed && hadAccount {
            let key = namespace + ":category-policy"
            if let stored = try context.fetch(
                FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.namespace == key })
            ).first {
                let policy = try SyncPayload.decode(SyncNamespacePolicy.self, from: stored.data)
                row.generationsData = policy.generations
                row.retiredGenerationsData = policy.retiredGenerations
            } else {
                row.generationsData = Data("{}".utf8)
                row.retiredGenerationsData = Data("{}".utf8)
            }
        }
        let unattached = try context.fetch(
            FetchDescriptor<SyncRecordState>(predicate: #Predicate { $0.namespace == "local" }))
        for state in unattached {
            let key = try Self.key(
                namespace: namespace, kind: state.kindRawValue, entityID: state.entityID,
                generation: SyncPayload.decode(SyncEnvelope.self, from: state.envelopeData).generation)
            if try recordState(key: key) == nil {
                state.namespace = namespace
                state.key = key
                state.systemFields = nil
                state.acknowledgedRevision = 0
            }
        }
        try save()
    }

    func bootstrapLocalRecords() throws {
        try LibrarySyncJournal.transaction(in: context) {
            try PlaylistStore.adoptLegacyFavorites(in: context)
            try RecommendationSyncBridge.prune(in: context)
        }
    }

    /// Every batch commits its journal before yielding. Interrupted bootstrap can simply
    /// enumerate again: unchanged entity snapshots are idempotent, and normal edits already
    /// have explicit journal hooks while this method is suspended.
    func bootstrapLocalRecordsInBatches(checkCancellation: () throws -> Void) async throws {
        try checkCancellation()
        try LibrarySyncJournal.transaction(in: context, captureChanges: false, notifySync: false) {
            try PlaylistStore.adoptLegacyFavorites(in: context)
            try RecommendationSyncBridge.prepare(in: context)
        }
        let identities = try localIdentities()
        for offset in stride(from: 0, to: identities.count, by: 100) {
            try checkCancellation()
            try LibrarySyncJournal.transaction(in: context, captureChanges: false, notifySync: false) {
                for (kind, entityID) in identities[offset..<min(offset + 100, identities.count)] {
                    try LibrarySyncJournal.capture(kind: kind, entityID: entityID, in: context)
                }
            }
            await Task.yield()
        }
        try checkCancellation()
        try finishIncomingBatch()
    }

    private func localIdentities() throws -> [(SyncKind, String)] {
        var values: [(SyncKind, String)] = []
        func append<T: PersistentModel>(_ type: T.Type, kind: SyncKind, identity: (T) -> String?) throws {
            var offset = 0
            while true {
                var page = FetchDescriptor<T>()
                page.fetchLimit = 100
                page.fetchOffset = offset
                let rows = try context.fetch(page)
                for row in rows {
                    if let id = identity(row) { values.append((kind, id)) }
                }
                if rows.count < 100 { break }
                offset += rows.count
            }
        }
        // Enumerating identities does not allocate encoded payloads or modify rows, and there
        // is no suspension until this stable list has been collected.
        try append(SubscribedChannel.self, kind: .subscription) { $0.channelID }
        try append(HistoryEntry.self, kind: .history) { $0.videoID }
        try append(Playlist.self, kind: .playlist) { $0.id.uuidString.lowercased() }
        try append(PlaylistVideo.self, kind: .playlistVideo) { row in
            guard let parent = row.playlist else { return nil }
            return LibrarySyncJournal.playlistVideoIdentity(
                playlistID: parent.id, videoID: row.videoID, incarnation: parent.syncIncarnation)
        }
        try append(Feedback.self, kind: .feedback) { $0.videoID }
        try append(SearchEntry.self, kind: .search) { $0.query }
        try append(SyncPreference.self, kind: .preference) { $0.key }
        try append(RecommendationOutcomeEntry.self, kind: .activity) { $0.eventID?.uuidString.lowercased() }
        try append(FeedImpressionBaseline.self, kind: .impressionBaseline) { $0.id.uuidString.lowercased() }
        values.append((.activity, RecommendationSyncBridge.retentionEntityID))
        return values
    }

    func pendingCount() throws -> Int {
        let namespace = try currentNamespace()
        return try context.fetchCount(
            FetchDescriptor<SyncRecordState>(
                predicate: #Predicate {
                    $0.namespace == namespace && ($0.isObsolete || $0.localRevision > $0.acknowledgedRevision)
                }))
    }

    /// `excluding` holds journal keys that are in flight or have failed in this session;
    /// they are skipped so one poison record cannot block unrelated work.
    func pendingRecords(limit: Int = 100, byteLimit: Int = 2 * 1_024 * 1_024, excluding: Set<String> = []) throws
        -> [SyncPendingRecord]
    {
        guard limit > 0, byteLimit > 0 else { return [] }
        let namespace = try currentNamespace()
        let policyKind = SyncKind.policy.rawValue
        let activityKind = SyncKind.activity.rawValue
        let retentionID = RecommendationSyncBridge.retentionEntityID
        let maximum = max(0, min(limit, 100))
        let fetchLimit = maximum + excluding.count
        var policyDescriptor = FetchDescriptor<SyncRecordState>(
            predicate: #Predicate {
                $0.namespace == namespace && !$0.isObsolete
                    && ($0.kindRawValue == policyKind
                        || ($0.kindRawValue == activityKind && $0.entityID == retentionID))
                    && $0.localRevision > $0.acknowledgedRevision
            }, sortBy: [SortDescriptor(\.localRevision)])
        policyDescriptor.fetchLimit = fetchLimit
        let policies = try context.fetch(policyDescriptor).filter { !excluding.contains($0.key) }
        var rows = Array(policies.prefix(maximum))
        if rows.count < maximum {
            var descriptor = FetchDescriptor<SyncRecordState>(
                predicate: #Predicate {
                    $0.namespace == namespace && !$0.isObsolete
                        && !($0.kindRawValue == policyKind
                            || ($0.kindRawValue == activityKind && $0.entityID == retentionID))
                        && $0.localRevision > $0.acknowledgedRevision
                }, sortBy: [SortDescriptor(\.localRevision)])
            descriptor.fetchLimit = fetchLimit
            let others = try context.fetch(descriptor).filter { !excluding.contains($0.key) }
            rows.append(contentsOf: others.prefix(maximum - rows.count))
        }
        var result: [SyncPendingRecord] = []
        var bytes = 0
        for row in rows {
            let envelope = try SyncPayload.decode(SyncEnvelope.self, from: row.envelopeData)
            let currentGeneration = try generation(for: envelope.kind)
            guard envelope.kind == .policy || envelope.generation == currentGeneration else { continue }
            guard row.envelopeData.count <= byteLimit - bytes else { break }
            bytes += row.envelopeData.count
            result.append(
                SyncPendingRecord(
                    key: row.key, envelope: envelope, revision: row.localRevision, systemFields: row.systemFields))
        }
        // Barriers must leave the device before a new generation's content.
        return result.sorted { ($0.envelope.kind == .policy ? 0 : 1) < ($1.envelope.kind == .policy ? 0 : 1) }
    }

    /// The server no longer has the record our saved change tag describes (it was
    /// collected by another device). The next upload recreates it from scratch.
    func clearSystemFields(key: String) throws {
        guard let row = try recordState(key: key), row.namespace == (try currentNamespace()) else { return }
        row.systemFields = nil
        try save()
    }

    // MARK: Quarantine

    /// A fetched record this version cannot apply (corrupt, over capacity, or otherwise
    /// rejected) is kept verbatim so the engine checkpoint can advance past it. Nothing
    /// in the cloud is modified; the item is retried on the next session and after updates.
    nonisolated struct QuarantinedRecord: Codable, Sendable {
        var recordName: String
        var payload: Data
        var systemFields: Data
        var reason: String
        var quarantinedAt: Date
    }

    private static let quarantineNamespace = "quarantine"
    private static let maximumQuarantinedRecords = 2_000

    func quarantine(recordName: String, payload: Data, systemFields: Data, reason: String) throws {
        let prefix = try currentNamespace() + ":" + Self.quarantineNamespace + ":"
        let key = prefix + recordName
        let existing = try context.fetch(FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.namespace == key }))
            .first
        if existing == nil {
            let count = try context.fetch(FetchDescriptor<SyncCheckpoint>()).filter { $0.namespace.hasPrefix(prefix) }
                .count
            guard count < Self.maximumQuarantinedRecords else {
                throw SyncStorageError.capacityExceeded("quarantined items")
            }
        }
        let record = QuarantinedRecord(
            recordName: recordName, payload: payload, systemFields: systemFields,
            reason: reason, quarantinedAt: .now)
        let data = try JSONEncoder().encode(record)
        if let existing {
            existing.data = data
            existing.updatedAt = .now
        } else {
            context.insert(SyncCheckpoint(namespace: key, data: data))
        }
        try save()
    }

    func quarantinedRecords() throws -> [QuarantinedRecord] {
        let prefix = try currentNamespace() + ":" + Self.quarantineNamespace + ":"
        return try context.fetch(FetchDescriptor<SyncCheckpoint>())
            .filter { $0.namespace.hasPrefix(prefix) }
            .compactMap { try? JSONDecoder().decode(QuarantinedRecord.self, from: $0.data) }
    }

    func quarantinedCount() throws -> Int {
        let prefix = try currentNamespace() + ":" + Self.quarantineNamespace + ":"
        return try context.fetch(FetchDescriptor<SyncCheckpoint>()).filter { $0.namespace.hasPrefix(prefix) }.count
    }

    func releaseQuarantine(recordName: String) throws {
        let key = try currentNamespace() + ":" + Self.quarantineNamespace + ":" + recordName
        for row in try context.fetch(FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.namespace == key })) {
            context.delete(row)
        }
        try save()
    }

    /// `excluding` holds journal keys CloudKit rejected this session: a poisoned
    /// barrier must not hold every other upload and deletion hostage.
    func hasPendingBarriers(excluding: Set<String> = []) throws -> Bool {
        let namespace = try currentNamespace()
        let policyKind = SyncKind.policy.rawValue
        let activityKind = SyncKind.activity.rawValue
        let retentionID = RecommendationSyncBridge.retentionEntityID
        let descriptor = FetchDescriptor<SyncRecordState>(
            predicate: #Predicate {
                $0.namespace == namespace && !$0.isObsolete && $0.localRevision > $0.acknowledgedRevision
                    && ($0.kindRawValue == policyKind
                        || ($0.kindRawValue == activityKind && $0.entityID == retentionID))
            })
        if excluding.isEmpty { return try context.fetchCount(descriptor) > 0 }
        return try context.fetch(descriptor).contains { !excluding.contains($0.key) }
    }

    func pendingDeletions(limit: Int = 100) throws -> [SyncPendingRecord] {
        guard limit > 0 else { return [] }
        let namespace = try currentNamespace()
        var descriptor = FetchDescriptor<SyncRecordState>(
            predicate: #Predicate { $0.namespace == namespace && $0.isObsolete })
        descriptor.fetchLimit = max(0, min(limit, Self.maximumJournalRecords))
        return try context.fetch(descriptor).map {
            SyncPendingRecord(
                key: $0.key, envelope: try SyncPayload.decode(SyncEnvelope.self, from: $0.envelopeData),
                revision: $0.localRevision, systemFields: $0.systemFields)
        }
    }

    func acknowledgeDeletion(key: String) throws {
        guard let row = try recordState(key: key), row.isObsolete, row.namespace == (try currentNamespace()) else {
            return
        }
        context.delete(row)
        if let cachedJournalCount { self.cachedJournalCount = max(0, cachedJournalCount - 1) }
        try save()
    }

    func acknowledge(key: String, revision: Int64, systemFields: Data?) throws {
        guard let row = try recordState(key: key), row.namespace == (try currentNamespace()) else { return }
        if revision >= row.acknowledgedRevision { row.systemFields = systemFields }
        row.acknowledgedRevision = min(row.localRevision, max(row.acknowledgedRevision, revision))
        try save()
    }

    func loadCheckpoint(namespace: String) throws -> Data? {
        let key = try currentNamespace() + ":" + namespace
        return try context.fetch(FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.namespace == key })).first?
            .data
    }

    func saveCheckpoint(_ data: Data?, namespace: String) throws {
        let key = try currentNamespace() + ":" + namespace
        let existing = try context.fetch(FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.namespace == key }))
            .first
        if let data {
            guard data.count <= Self.maximumCheckpointBytes else {
                throw SyncStorageError.capacityExceeded("engine checkpoint")
            }
            if let existing {
                existing.data = data
                existing.updatedAt = .now
            } else {
                context.insert(SyncCheckpoint(namespace: key, data: data))
            }
        } else if let existing {
            context.delete(existing)
        }
        try save()
    }

    func discardTransportState() throws {
        let namespace = try currentNamespace()
        for row in try context.fetch(
            FetchDescriptor<SyncRecordState>(predicate: #Predicate { $0.namespace == namespace }))
        {
            row.systemFields = nil
        }
        let prefix = namespace + ":"
        for row in try context.fetch(FetchDescriptor<SyncCheckpoint>()) where row.namespace.hasPrefix(prefix) {
            context.delete(row)
        }
        try save()
    }

    /// Runs after a fetch round. `force` rescans even when nothing was applied since
    /// the previous pass (bootstrap and tests); ordinary rounds with no incoming
    /// changes skip the activity rescan entirely.
    func finishIncomingBatch(force: Bool = false) throws {
        guard force || appliedSinceLastFinish else { return }
        appliedSinceLastFinish = false
        try LibrarySyncJournal.transaction(in: context, captureChanges: false, notifySync: false) {
            try RecommendationSyncBridge.prune(in: context)
            let namespace = try currentNamespace()
            let activity = SyncKind.activity.rawValue
            let baseline = SyncKind.impressionBaseline.rawValue
            let rows = try context.fetch(
                FetchDescriptor<SyncRecordState>(
                    predicate: #Predicate {
                        $0.namespace == namespace && !$0.isObsolete
                            && ($0.kindRawValue == activity || $0.kindRawValue == baseline)
                    }))
            let retention = try RecommendationSyncBridge.retentionBarrier(in: context)
            for row in rows {
                let envelope = try SyncPayload.decode(SyncEnvelope.self, from: row.envelopeData)
                guard let payload = envelope.effectivePayload else {
                    // Compaction: the shared retention barrier, not the per-event tombstone,
                    // is what keeps an expired event from returning. Once the tombstone has
                    // been acknowledged by CloudKit it can become a physical deletion, after
                    // which its journal row is dropped. Without this the journal only grows.
                    let acknowledged = row.acknowledgedRevision >= row.localRevision && row.systemFields != nil
                    let neverUploaded = row.acknowledgedRevision == 0 && row.systemFields == nil
                    if envelope.isTombstone, acknowledged || neverUploaded {
                        try markObsolete(row, envelope: envelope)
                    }
                    continue
                }
                if try !RecommendationSyncBridge.shouldRetain(
                    kind: envelope.kind, entityID: envelope.entityID, payload: payload, barrier: retention)
                {
                    try markObsolete(row, envelope: envelope)
                }
            }
            try RecommendationSyncBridge.rebuildProjection(in: context)
            for snapshot in try snapshots(only: .activity, entityID: RecommendationSyncBridge.retentionEntityID) {
                try recordLocal(kind: snapshot.kind, entityID: snapshot.entityID, payload: snapshot.payload)
            }
        }
    }

    func resetPersonalization() throws {
        try LibrarySyncJournal.transaction(in: context) {
            for kind: SyncKind in [.history, .search, .feedback, .activity, .impressionBaseline] {
                try clear(kind: kind)
            }
        }
    }

    func generation(for kind: SyncKind) throws -> String {
        if kind == .policy { return "initial" }
        return try generations()[kind.rawValue] ?? "initial"
    }

    func state(kind: SyncKind, entityID: String) throws -> SyncRecordState? {
        try recordState(
            key: Self.key(
                namespace: currentNamespace(), kind: kind.rawValue, entityID: entityID,
                generation: generation(for: kind)))
    }

    fileprivate func recordLocal(kind: SyncKind, entityID: String, payload: Data?) throws {
        if let payload { try validate(kind: kind, entityID: entityID, payload: payload) }
        let row = try state(kind: kind, entityID: entityID)
        if let row, row.materializedPayload == payload,
            let prior = try? SyncPayload.decode(SyncEnvelope.self, from: row.envelopeData),
            prior.isTombstone == (payload == nil)
        {
            return
        }
        let currentGeneration = try generation(for: kind)
        var decoded = try row.map { try SyncPayload.decode(SyncEnvelope.self, from: $0.envelopeData) }
        // A secondary importer/intent context may have committed since this context fetched its row.
        let freshContext = freshReadContext()
        let key = try Self.key(
            namespace: currentNamespace(), kind: kind.rawValue, entityID: entityID, generation: currentGeneration)
        if let disk = try freshContext.fetch(FetchDescriptor<SyncRecordState>(predicate: #Predicate { $0.key == key }))
            .first
        {
            let diskEnvelope = try SyncPayload.decode(SyncEnvelope.self, from: disk.envelopeData)
            if let existing = decoded, existing.generation == diskEnvelope.generation {
                decoded = try SyncMergePolicy.merge(existing, diskEnvelope)
            } else {
                decoded = diskEnvelope
            }
        }
        let prior = decoded?.generation == currentGeneration ? decoded : nil
        let enrollment = try enrollment()
        // A restored backup mints a new writer whose counter restarts at zero; the
        // new revision must still exceed what CloudKit has already acknowledged.
        let counter = try nextRevision(
            observing: prior, atLeast: max(row?.acknowledgedRevision ?? 0, row?.localRevision ?? 0))
        var mutationPayload = payload
        if kind == .search, let payload, let priorPayload = prior?.effectivePayload,
            priorPayload != row?.materializedPayload
        {
            var candidate = try SyncPayload.decode(SyncSearchPayload.self, from: payload)
            let freshest = try SyncPayload.decode(SyncSearchPayload.self, from: priorPayload)
            let observed = try row?.materializedPayload.map { try SyncPayload.decode(SyncSearchPayload.self, from: $0) }
            let writer = enrollment.installationID
            let increment = max(0, (candidate.components[writer] ?? 0) - (observed?.components[writer] ?? 0))
            candidate.legacyCount = max(candidate.legacyCount, freshest.legacyCount)
            for (id, count) in freshest.components {
                candidate.components[id] = max(candidate.components[id] ?? 0, count)
            }
            candidate.components[writer] = min(1_000_000, (freshest.components[writer] ?? 0) + increment)
            mutationPayload = try SyncPayload.encode(candidate)
            _ = try materialize(kind: kind, entityID: entityID, payload: mutationPayload)
        }
        let envelope = try SyncEnvelope.mutation(
            kind: kind, entityID: entityID, generation: currentGeneration, from: prior,
            payload: mutationPayload, writerID: enrollment.installationID, counter: UInt64(counter))
        let stored = try row ?? insertState(envelope)
        stored.envelopeData = try SyncPayload.encode(envelope)
        stored.localRevision = counter
        stored.materializedPayload = mutationPayload
        stored.isMaterialized = true
        if kind == .playlist, let mutationPayload {
            stored.playlistIncarnation =
                try SyncPayload.decode(SyncPlaylistPayload.self, from: mutationPayload).syncIncarnation ?? "initial"
        }
        if payload == nil { stored.deletionMarker = enrollment.installationID + ":" + String(counter) }
    }

    /// Snapshot reconciliation supplements explicit mutation hooks. Absence is never deletion:
    /// an incoming child may legitimately be staged until its parent arrives.
    fileprivate func captureLocalChanges() throws {
        for snapshot in try snapshots() {
            let row = try state(kind: snapshot.kind, entityID: snapshot.entityID)
            guard row?.materializedPayload != snapshot.payload else { continue }
            try recordLocal(kind: snapshot.kind, entityID: snapshot.entityID, payload: snapshot.payload)
        }
    }

    fileprivate func retire(kind: SyncKind, entityID: String) throws {
        guard let row = try state(kind: kind, entityID: entityID) else { return }
        let envelope = try SyncPayload.decode(SyncEnvelope.self, from: row.envelopeData)
        try markObsolete(row, envelope: envelope)
    }

    func clear(kind: SyncKind) throws {
        guard kind != .policy, kind != .preference else { throw SyncStorageError.unsupportedKind }
        let newGeneration = UUID().uuidString.lowercased()
        let payload = try SyncPayload.encode(SyncCategoryPolicy(kind: kind, generation: newGeneration))
        try recordLocal(kind: .policy, entityID: kind.rawValue, payload: payload)
        try applyCategoryPolicy(SyncCategoryPolicy(kind: kind, generation: newGeneration))
    }

    /// Saves model changes and their causal metadata together. The caller may persist an engine
    /// checkpoint only after this succeeds; a thrown error leaves replay safe.
    @discardableResult
    func apply(_ incoming: SyncEnvelope, systemFields: Data? = nil, rebuildProjection: Bool = true) throws
        -> SyncEnvelope
    {
        lastApplyChangedProjection = false
        rebuildActivityProjection = rebuildProjection
        defer { rebuildActivityProjection = true }
        do {
            // Unrelated autosaved edits (a download row, a cache entry) must survive
            // this record's rollback; commit them on their own first.
            if context.hasChanges { try context.save() }
            return try LibrarySyncJournal.remote(in: context) {
                let result = try applyWithoutSaving(incoming, systemFields: systemFields)
                try context.save()
                appliedSinceLastFinish = true
                if result.kind == .preference, let data = result.effectivePayload {
                    let preference = try SyncPayload.decode(SyncPreferencePayload.self, from: data)
                    PortablePreferenceStore.applySyncedValue(key: preference.key, value: preference.value)
                }
                if lastApplyChangedProjection { WatchedIDsMemo.noteMembershipChange() }
                return result
            }
        } catch {
            context.rollback()
            throw error
        }
    }

    private func applyWithoutSaving(_ incoming: SyncEnvelope, systemFields: Data?) throws -> SyncEnvelope {
        // Validate the envelope itself before trusting tombstone or generation fields.
        try incoming.validate()
        for version in incoming.register.versions {
            if let data = version.payload {
                try validate(kind: incoming.kind, entityID: incoming.entityID, payload: data)
            }
        }
        let row = try recordState(
            key: Self.key(
                namespace: currentNamespace(), kind: incoming.kind.rawValue, entityID: incoming.entityID,
                generation: incoming.generation))
        let local = try row.map { try SyncPayload.decode(SyncEnvelope.self, from: $0.envelopeData) }
        var merged = incoming
        var reassertedRevision: Int64?
        if let local, local.generation == incoming.generation {
            if incoming.kind == .preference {
                let key = incoming.entityID
                let localExplicit =
                    try context.fetch(FetchDescriptor<SyncPreference>(predicate: #Predicate { $0.key == key })).first?
                    .isExplicit ?? false
                let incomingExplicit =
                    try incoming.effectivePayload.map {
                        try SyncPayload.decode(SyncPreferencePayload.self, from: $0).isExplicit ?? true
                    } ?? true
                if !localExplicit {
                    // A cloud value (explicit or not) beats an unedited local default.
                } else if !incomingExplicit, let chosen = local.effectivePayload {
                    // The user's explicit choice beats another device's migration
                    // baseline regardless of causal tie-breaks: observe the incoming
                    // version, then re-issue the local value above the joined frontier.
                    let joined = try SyncMergePolicy.merge(local, incoming)
                    if joined.effectivePayload == chosen {
                        merged = joined
                    } else {
                        let counter = try nextRevision(
                            observing: joined,
                            atLeast: max(row?.acknowledgedRevision ?? 0, row?.localRevision ?? 0))
                        merged = try SyncEnvelope.mutation(
                            kind: incoming.kind, entityID: incoming.entityID, generation: incoming.generation,
                            from: joined, payload: chosen, writerID: enrollment().installationID,
                            counter: UInt64(counter))
                        reassertedRevision = counter
                    }
                } else {
                    merged = try SyncMergePolicy.merge(local, incoming)
                }
            } else {
                merged = try SyncMergePolicy.merge(local, incoming)
            }
        }
        if incoming.kind != .policy, incoming.generation != (try generation(for: incoming.kind)) {
            // A known old generation is rejected; a not-yet-observed policy's data is staged.
            // The full encrypted envelope remains durable for retry after the policy arrives.
            let staged = try row ?? insertState(incoming)
            staged.envelopeData = try SyncPayload.encode(merged)
            staged.systemFields = systemFields
            staged.acknowledgedRevision = staged.localRevision
            if try retiredGenerations()[incoming.kind.rawValue, default: []].contains(incoming.generation) {
                try markObsolete(staged, envelope: merged)
            }
            return merged
        }
        let priorPayload = row?.materializedPayload
        let previouslyMaterialized = row?.isMaterialized ?? false
        let stored = try row ?? insertState(merged)
        stored.envelopeData = try SyncPayload.encode(merged)
        stored.systemFields = systemFields
        if merged.kind == .playlist, let payload = merged.effectivePayload ?? local?.effectivePayload {
            stored.playlistIncarnation =
                try SyncPayload.decode(SyncPlaylistPayload.self, from: payload).syncIncarnation ?? "initial"
        }
        if let reassertedRevision {
            stored.localRevision = reassertedRevision
        } else if merged != incoming {
            stored.localRevision = try nextRevision(
                atLeast: max(stored.acknowledgedRevision, stored.localRevision))
        } else {
            stored.acknowledgedRevision = stored.localRevision
        }
        if merged.isTombstone {
            stored.deletionMarker = Self.tombstoneMarker(merged)
        }
        let materialized: Bool
        if previouslyMaterialized && priorPayload == merged.effectivePayload && merged.kind != .policy {
            materialized = true
        } else {
            materialized = try materialize(
                kind: merged.kind, entityID: merged.entityID, payload: merged.effectivePayload)
        }
        lastApplyChangedProjection = materialized && priorPayload != merged.effectivePayload
        stored.isMaterialized = materialized
        stored.materializedPayload = materialized ? merged.effectivePayload : nil
        if merged.kind == .activity || merged.kind == .impressionBaseline, let data = merged.effectivePayload,
            try !RecommendationSyncBridge.shouldRetain(
                kind: merged.kind, entityID: merged.entityID, payload: data, in: context)
        {
            try markObsolete(stored, envelope: merged)
        }
        if merged.kind == .playlistVideo, !materialized, let payload = merged.effectivePayload {
            let child = try SyncPayload.decode(SyncPlaylistVideoPayload.self, from: payload)
            if let parent = try state(kind: .playlist, entityID: child.playlistID.uuidString.lowercased()),
                parent.playlistIncarnation == (child.parentIncarnation ?? "initial"),
                try SyncPayload.decode(SyncEnvelope.self, from: parent.envelopeData).isTombstone
            {
                try markObsolete(stored, envelope: merged)
            }
        }
        if stored.isDeleted { return merged }
        if stored.isObsolete {
            stored.isMaterialized = false
            stored.materializedPayload = nil
        }
        if merged.kind == .playlist, !merged.isTombstone { try materializePendingChildren(parentID: merged.entityID) }
        return merged
    }

    private func materializePendingChildren(parentID: String) throws {
        let namespace = try currentNamespace()
        let kind = SyncKind.playlistVideo.rawValue
        let rows = try context.fetch(
            FetchDescriptor<SyncRecordState>(
                predicate: #Predicate {
                    $0.namespace == namespace && $0.kindRawValue == kind && !$0.isMaterialized && !$0.isObsolete
                }))
        for row in rows {
            let envelope = try SyncPayload.decode(SyncEnvelope.self, from: row.envelopeData)
            guard envelope.generation == (try generation(for: .playlistVideo)), let data = envelope.effectivePayload
            else { continue }
            let payload = try SyncPayload.decode(SyncPlaylistVideoPayload.self, from: data)
            guard payload.playlistID.uuidString.lowercased() == parentID else { continue }
            row.isMaterialized = try materialize(kind: .playlistVideo, entityID: row.entityID, payload: data)
            if row.isMaterialized { row.materializedPayload = data }
        }
    }

    private func applyCategoryPolicy(_ policy: SyncCategoryPolicy) throws {
        var values = try generations()
        if values[policy.kind.rawValue] == policy.generation { return }
        var retired = try retiredGenerations()
        let previous = values[policy.kind.rawValue] ?? "initial"
        var retiredKind = Set(retired[policy.kind.rawValue] ?? [])
        retiredKind.insert(previous)
        retiredKind.remove(policy.generation)
        retired[policy.kind.rawValue] = retiredKind.sorted()
        values[policy.kind.rawValue] = policy.generation
        let enrollment = try enrollment()
        enrollment.generationsData = try SyncPayload.encode(values)
        enrollment.retiredGenerationsData = try SyncPayload.encode(retired)
        try deleteAllMaterialized(kind: policy.kind)
        let namespace = try currentNamespace()
        let kind = policy.kind.rawValue
        let rows = try context.fetch(
            FetchDescriptor<SyncRecordState>(
                predicate: #Predicate {
                    $0.namespace == namespace && $0.kindRawValue == kind
                }))
        for row in rows {
            let envelope = try SyncPayload.decode(SyncEnvelope.self, from: row.envelopeData)
            if envelope.generation == policy.generation {
                row.isMaterialized = try materialize(
                    kind: envelope.kind, entityID: envelope.entityID, payload: envelope.effectivePayload)
                row.materializedPayload = row.isMaterialized ? envelope.effectivePayload : nil
            } else if retiredKind.contains(envelope.generation) {
                try markObsolete(row, envelope: envelope)
            }
        }
    }

    /// An obsolete row is a pending physical deletion in CloudKit. A library that
    /// has never been bound to an account has nothing there to delete, so its rows
    /// are dropped outright instead of accumulating until enrollment (or forever).
    private func markObsolete(_ row: SyncRecordState, envelope: SyncEnvelope) throws {
        guard !row.isObsolete, !row.isDeleted else { return }
        if try currentNamespace() == "local" {
            context.delete(row)
            if let cachedJournalCount { self.cachedJournalCount = max(0, cachedJournalCount - 1) }
            return
        }
        let counter = try nextRevision(
            observing: envelope, atLeast: max(row.acknowledgedRevision, row.localRevision))
        let tombstone = try SyncEnvelope.mutation(
            kind: envelope.kind, entityID: envelope.entityID, generation: envelope.generation, from: envelope,
            payload: nil, writerID: enrollment().installationID, counter: UInt64(counter))
        row.envelopeData = try SyncPayload.encode(tombstone)
        row.materializedPayload = nil
        row.isMaterialized = false
        row.isObsolete = true
        row.localRevision = counter
    }

    private func retiredGenerations() throws -> [String: [String]] {
        try SyncPayload.decode([String: [String]].self, from: enrollment().retiredGenerationsData)
    }

    private func currentNamespace() throws -> String {
        let row = try enrollment()
        guard let account = row.accountID, let generation = row.libraryGeneration else { return "local" }
        return row.environment + ":" + account + ":" + generation
    }

    private static func key(namespace: String, kind: String, entityID: String, generation: String) -> String {
        namespace + ":" + kind + ":" + generation + ":" + entityID
    }

    private func recordState(key: String) throws -> SyncRecordState? {
        try context.fetch(FetchDescriptor<SyncRecordState>(predicate: #Predicate { $0.key == key })).first
    }

    private func insertState(_ envelope: SyncEnvelope) throws -> SyncRecordState {
        // One count per adapter; each insert through this adapter bumps the cached value.
        var count = try cachedJournalCount ?? context.fetchCount(FetchDescriptor<SyncRecordState>())
        if count >= Self.maximumJournalRecords {
            count = try compactJournal()
        }
        guard count < Self.maximumJournalRecords else {
            throw SyncStorageError.capacityExceeded("sync journal")
        }
        cachedJournalCount = count + 1
        let namespace = try currentNamespace()
        let row = SyncRecordState(
            key: Self.key(
                namespace: namespace, kind: envelope.kind.rawValue, entityID: envelope.entityID,
                generation: envelope.generation), namespace: namespace, kind: envelope.kind.rawValue,
            entityID: envelope.entityID, envelopeData: try SyncPayload.encode(envelope))
        context.insert(row)
        return row
    }

    /// Runs only when the journal is full. Rows for other accounts' namespaces and
    /// obsolete rows CloudKit never saw (no change tag, never acknowledged) carry no
    /// cloud state worth keeping; a later rebind re-captures the library anyway.
    @discardableResult
    func compactJournal() throws -> Int {
        let namespace = try currentNamespace()
        let stale = try context.fetch(
            FetchDescriptor<SyncRecordState>(
                predicate: #Predicate {
                    $0.namespace != namespace
                        || ($0.isObsolete && $0.acknowledgedRevision == 0 && $0.systemFields == nil)
                }))
        for row in stale { context.delete(row) }
        if !stale.isEmpty { try save() }
        let count = try context.fetchCount(FetchDescriptor<SyncRecordState>())
        cachedJournalCount = count
        return count
    }

    private func generations() throws -> [String: String] {
        try SyncPayload.decode([String: String].self, from: enrollment().generationsData)
    }

    private func nextRevision(observing envelope: SyncEnvelope? = nil, atLeast minimum: Int64 = 0) throws -> Int64 {
        let row = try enrollment()
        if !didReadDiskEnrollment {
            diskEnrollment = try freshReadContext().fetch(FetchDescriptor<SyncEnrollment>()).first
            didReadDiskEnrollment = true
        }
        let diskCounter = diskEnrollment?.installationID == row.installationID ? diskEnrollment?.counter ?? 0 : 0
        let causalCounter = envelope?.register.context.counters[row.installationID] ?? 0
        guard causalCounter < UInt64(Int64.max) else { throw SyncStorageError.revisionExhausted }
        let floor = max(
            row.counter, diskCounter, Self.allocatedRevisions[row.installationID] ?? 0, Int64(causalCounter),
            minimum)
        guard floor < Int64.max else { throw SyncStorageError.revisionExhausted }
        row.counter = floor + 1
        Self.allocatedRevisions[row.installationID] = row.counter
        return row.counter
    }

    private static func tombstoneMarker(_ envelope: SyncEnvelope) -> String {
        // Only causal deletion identity is included; no titles, URLs, or playback data.
        envelope.register.versions.filter { $0.payload == nil }.map {
            $0.dot.installationID + ":" + String($0.dot.counter)
        }.sorted().joined(separator: ",")
    }

    private func save() throws {
        do { try context.save() } catch {
            context.rollback()
            throw error
        }
    }
}

extension SyncStoreAdapter {
    private typealias Snapshot = (kind: SyncKind, entityID: String, payload: Data)

    fileprivate func capture(kind: SyncKind, entityID: String) throws {
        for snapshot in try snapshots(only: kind, entityID: entityID) {
            try recordLocal(kind: snapshot.kind, entityID: snapshot.entityID, payload: snapshot.payload)
        }
    }

    private func snapshots(only kind: SyncKind? = nil, entityID: String? = nil) throws -> [Snapshot] {
        var result: [Snapshot] = []
        let identifier = entityID ?? ""
        if kind == nil || kind == .subscription {
            let descriptor =
                entityID == nil
                ? FetchDescriptor<SubscribedChannel>()
                : FetchDescriptor<SubscribedChannel>(predicate: #Predicate { $0.channelID == identifier })
            for row in try context.fetch(descriptor) {
                result.append(
                    (
                        .subscription, row.channelID,
                        try SyncPayload.encode(
                            SyncSubscriptionPayload(
                                channelID: row.channelID, name: row.name, avatarURL: row.avatarURL,
                                subscribedAt: row.subscribedAt))
                    ))
            }
        }
        if kind == nil || kind == .history {
            let descriptor =
                entityID == nil
                ? FetchDescriptor<HistoryEntry>()
                : FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == identifier })
            for row in try context.fetch(descriptor) {
                result.append(
                    (
                        .history, row.videoID,
                        try SyncPayload.encode(
                            SyncHistoryPayload(
                                videoID: row.videoID, title: row.title, uploader: row.uploader,
                                thumbnailURL: row.thumbnailURL, watchedAt: row.watchedAt,
                                positionSeconds: row.positionSeconds, durationSeconds: row.durationSeconds,
                                playbackSessionID: row.playbackSessionID,
                                playbackSessionStartedAt: row.playbackSessionStartedAt,
                                playbackSequence: row.playbackSequence))
                    ))
            }
        }
        if kind == nil || kind == .playlist {
            let id = UUID(uuidString: identifier) ?? UUID()
            let descriptor =
                entityID == nil
                ? FetchDescriptor<Playlist>() : FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
            for row in try context.fetch(descriptor) {
                result.append(
                    (
                        .playlist, row.id.uuidString.lowercased(),
                        try SyncPayload.encode(
                            SyncPlaylistPayload(
                                id: row.id, name: row.name, createdAt: row.createdAt, systemKind: row.systemKind,
                                legacyIDs: row.legacyIDs, syncIncarnation: row.syncIncarnation))
                    ))
            }
        }
        if kind == nil || kind == .playlistVideo {
            let parts = identifier.split(separator: ":", maxSplits: 2).map(String.init)
            let videoID = parts.last ?? ""
            let descriptor =
                entityID == nil
                ? FetchDescriptor<PlaylistVideo>()
                : FetchDescriptor<PlaylistVideo>(predicate: #Predicate { $0.videoID == videoID })
            for row in try context.fetch(descriptor) {
                guard let parent = row.playlist else { continue }
                let key = LibrarySyncJournal.playlistVideoIdentity(
                    playlistID: parent.id, videoID: row.videoID, incarnation: parent.syncIncarnation)
                guard entityID == nil || entityID == key else { continue }
                result.append(
                    (
                        .playlistVideo, key,
                        try SyncPayload.encode(
                            SyncPlaylistVideoPayload(
                                playlistID: parent.id, parentIncarnation: parent.syncIncarnation, videoID: row.videoID,
                                title: row.title, uploader: row.uploader, thumbnailURL: row.thumbnailURL,
                                duration: PersistedMetadataPolicy.sanitizedPlaybackDuration(row.duration),
                                addedAt: row.addedAt))
                    ))
            }
        }
        if kind == nil || kind == .feedback {
            let descriptor =
                entityID == nil
                ? FetchDescriptor<Feedback>()
                : FetchDescriptor<Feedback>(predicate: #Predicate { $0.videoID == identifier })
            for row in try context.fetch(descriptor) {
                result.append(
                    (
                        .feedback, row.videoID,
                        try SyncPayload.encode(
                            SyncFeedbackPayload(
                                videoID: row.videoID, signal: row.signal, title: row.title, uploader: row.uploader,
                                category: row.category, tags: row.tags, createdAt: row.createdAt))
                    ))
            }
        }
        if kind == nil || kind == .search {
            let descriptor =
                entityID == nil
                ? FetchDescriptor<SearchEntry>()
                : FetchDescriptor<SearchEntry>(predicate: #Predicate { $0.query == identifier })
            let writer = try enrollment().installationID
            for row in try context.fetch(descriptor) {
                var payload: SyncSearchPayload
                if let previous = try state(kind: .search, entityID: row.query)?.materializedPayload {
                    payload = try SyncPayload.decode(SyncSearchPayload.self, from: previous)
                    let delta = max(0, row.count - payload.count)
                    if delta > 0 {
                        payload.components[writer] = min(1_000_000, (payload.components[writer] ?? 0) + delta)
                    }
                    payload.displayQuery = row.displayQuery
                    payload.lastSearchedAt = row.lastSearchedAt
                } else {
                    payload = SyncSearchPayload(
                        query: row.query, displayQuery: row.displayQuery, lastSearchedAt: row.lastSearchedAt,
                        legacyCount: row.count, components: [:])
                }
                result.append((.search, row.query, try SyncPayload.encode(payload)))
            }
        }
        if kind == nil || kind == .preference {
            let descriptor =
                entityID == nil
                ? FetchDescriptor<SyncPreference>()
                : FetchDescriptor<SyncPreference>(predicate: #Predicate { $0.key == identifier })
            for row in try context.fetch(descriptor) {
                result.append(
                    (
                        .preference, row.key,
                        try SyncPayload.encode(
                            SyncPreferencePayload(
                                key: row.key, value: row.value, modifiedAt: row.modifiedAt,
                                isExplicit: row.isExplicit))
                    ))
            }
        }
        if kind == nil || kind == .activity || kind == .impressionBaseline {
            for snapshot in try RecommendationSyncBridge.snapshots(in: context, kind: kind, entityID: entityID) {
                if (kind == nil || kind == snapshot.kind) && (entityID == nil || snapshot.entityID == entityID) {
                    result.append(snapshot)
                }
            }
        }
        return result
    }

    private func validate(kind: SyncKind, entityID: String, payload: Data) throws {
        switch kind {
        case .subscription:
            let value = try SyncPayload.decode(SyncSubscriptionPayload.self, from: payload)
            guard value.channelID == entityID else { throw SyncStorageError.invalidPayload }
            try PersistedMetadataPolicy.requireIdentifier(value.channelID, field: "subscription.id")
            try PersistedMetadataPolicy.requireText(value.name, field: "subscription.name")
            try PersistedMetadataPolicy.requireOptionalURL(value.avatarURL, field: "subscription.avatar")
            try validateDate(value.subscribedAt)
        case .history:
            let value = try SyncPayload.decode(SyncHistoryPayload.self, from: payload)
            guard value.videoID == entityID, value.playbackSequence >= 0 else { throw SyncStorageError.invalidPayload }
            try validateVideo(
                id: value.videoID, title: value.title, uploader: value.uploader, thumbnail: value.thumbnailURL)
            try PersistedMetadataPolicy.requirePlaybackNumber(value.positionSeconds, field: "history.position")
            try PersistedMetadataPolicy.requirePlaybackNumber(value.durationSeconds, field: "history.duration")
            try validateDate(value.watchedAt)
            if let date = value.playbackSessionStartedAt { try validateDate(date) }
            if let session = value.playbackSessionID {
                try PersistedMetadataPolicy.requireIdentifier(session, field: "history.session")
            }
        case .playlist:
            let value = try SyncPayload.decode(SyncPlaylistPayload.self, from: payload)
            guard value.id.uuidString.lowercased() == entityID,
                value.systemKind == nil || value.systemKind == "favorites",
                value.systemKind != "favorites" || value.id == UUID(uuidString: "00000000-0000-4000-8000-000000000001"),
                (value.legacyIDs?.count ?? 0) <= 128
            else { throw SyncStorageError.invalidPayload }
            try PersistedMetadataPolicy.requireNonemptyText(value.name, field: "playlist.name")
            try validateDate(value.createdAt)
        case .playlistVideo:
            let value = try SyncPayload.decode(SyncPlaylistVideoPayload.self, from: payload)
            guard
                LibrarySyncJournal.playlistVideoIdentity(
                    playlistID: value.playlistID, videoID: value.videoID, incarnation: value.parentIncarnation)
                    == entityID
            else { throw SyncStorageError.invalidPayload }
            try validateVideo(
                id: value.videoID, title: value.title, uploader: value.uploader, thumbnail: value.thumbnailURL)
            try PersistedMetadataPolicy.requirePlaybackDuration(value.duration, field: "playlistVideo.duration")
            try validateDate(value.addedAt)
        case .feedback:
            let value = try SyncPayload.decode(SyncFeedbackPayload.self, from: payload)
            guard value.videoID == entityID, value.signal == -1 || value.signal == 1 else {
                throw SyncStorageError.invalidPayload
            }
            try validateVideo(id: value.videoID, title: value.title, uploader: value.uploader, thumbnail: nil)
            try PersistedMetadataPolicy.requireOptionalText(value.category, field: "feedback.category")
            try PersistedMetadataPolicy.requireTags(value.tags, field: "feedback.tags")
            try validateDate(value.createdAt)
        case .search:
            let value = try SyncPayload.decode(SyncSearchPayload.self, from: payload)
            guard value.query == entityID, SearchEntry.normalize(value.query) == value.query,
                value.count >= 1, value.components.count <= 128,
                (0...1_000_000).contains(value.legacyCount),
                value.components.values.allSatisfy({ (0...1_000_000).contains($0) })
            else { throw SyncStorageError.invalidPayload }
            try PersistedMetadataPolicy.requireNonemptyText(value.query, field: "search.query")
            try PersistedMetadataPolicy.requireOptionalText(value.displayQuery, field: "search.displayQuery")
            for writer in value.components.keys {
                try PersistedMetadataPolicy.requireIdentifier(writer, field: "search.writer")
            }
            try validateDate(value.lastSearchedAt)
        case .preference:
            let value = try SyncPayload.decode(SyncPreferencePayload.self, from: payload)
            guard value.key == entityID, SyncPreferences.validate(key: value.key, value: value.value) else {
                throw SyncStorageError.invalidPayload
            }
            try validateDate(value.modifiedAt)
        case .policy:
            let value = try SyncPayload.decode(SyncCategoryPolicy.self, from: payload)
            guard value.kind.rawValue == entityID, value.kind != .policy, value.kind != .preference,
                UUID(uuidString: value.generation) != nil
            else { throw SyncStorageError.invalidPayload }
        case .activity, .impressionBaseline:
            // The activity bridge validates its versioned feature/retention payload during apply.
            // Enforce the same budget before either writing or staging it.
            guard payload.count <= 128 * 1_024 else { throw SyncStorageError.invalidPayload }
            _ = try RecommendationSyncBridge.mergedPayloads(kind: kind, entityID: entityID, payloads: [payload])
        }
    }

    private func validateVideo(id: String, title: String, uploader: String?, thumbnail: String?) throws {
        try PersistedMetadataPolicy.requireIdentifier(id, field: "video.id")
        try PersistedMetadataPolicy.requireText(title, field: "video.title")
        try PersistedMetadataPolicy.requireOptionalText(uploader, field: "video.uploader")
        try PersistedMetadataPolicy.requireOptionalURL(thumbnail, field: "video.thumbnail")
    }

    private func validateDate(_ date: Date) throws {
        try PersistedMetadataPolicy.requireFiniteDate(date, field: "sync.date")
        guard date <= Date().addingTimeInterval(86_400) else { throw SyncStorageError.invalidPayload }
    }

    private func requireCapacity<T: PersistentModel>(
        _ type: T.Type, maximum: Int, label: String, playlistVideo: Bool = false
    ) throws {
        guard try context.fetchCount(FetchDescriptor<T>()) < maximum,
            playlistVideo
                ? PersistedMetadataCapacity.allowsAddingPlaylistVideo(in: context)
                : PersistedMetadataCapacity.allowsAddingTopLevelRecord(in: context)
        else { throw SyncStorageError.capacityExceeded(label) }
    }

    private func materialize(kind: SyncKind, entityID: String, payload: Data?) throws -> Bool {
        guard let payload else {
            try deleteMaterialized(kind: kind, entityID: entityID)
            return true
        }
        try validate(kind: kind, entityID: entityID, payload: payload)
        switch kind {
        case .subscription:
            let value = try SyncPayload.decode(SyncSubscriptionPayload.self, from: payload)
            let existing = try context.fetch(
                FetchDescriptor<SubscribedChannel>(predicate: #Predicate { $0.channelID == entityID })
            ).first
            let row: SubscribedChannel
            if let existing {
                row = existing
            } else {
                try requireCapacity(
                    SubscribedChannel.self, maximum: PersistedMetadataPolicy.maximumChannels, label: "subscriptions")
                row = SubscribedChannel(channelID: entityID, name: value.name)
                context.insert(row)
            }
            row.name = value.name
            row.avatarURL = value.avatarURL
            row.subscribedAt = value.subscribedAt
        case .history:
            let value = try SyncPayload.decode(SyncHistoryPayload.self, from: payload)
            let existing = try context.fetch(
                FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == entityID })
            ).first
            let row: HistoryEntry
            if let existing {
                row = existing
            } else {
                try requireCapacity(
                    HistoryEntry.self, maximum: PersistedMetadataPolicy.maximumHistory, label: "history")
                row = HistoryEntry(videoID: entityID, title: value.title)
                context.insert(row)
            }
            row.title = value.title
            row.uploader = value.uploader
            row.thumbnailURL = value.thumbnailURL
            row.watchedAt = value.watchedAt
            row.positionSeconds = value.positionSeconds
            row.durationSeconds = value.durationSeconds
            row.playbackSessionID = value.playbackSessionID
            row.playbackSessionStartedAt = value.playbackSessionStartedAt
            row.playbackSequence = value.playbackSequence
        case .playlist:
            let value = try SyncPayload.decode(SyncPlaylistPayload.self, from: payload)
            let id = value.id
            let existing = try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })).first
            let row: Playlist
            if let existing {
                row = existing
            } else {
                try requireCapacity(
                    Playlist.self, maximum: PersistedMetadataPolicy.maximumPlaylists, label: "playlists")
                row = Playlist(id: id, name: value.name)
                context.insert(row)
            }
            if row.syncIncarnation != value.syncIncarnation {
                for child in row.videos { context.delete(child) }
                row.videos.removeAll()
            }
            row.syncIncarnation = value.syncIncarnation
            row.name = value.systemKind == "favorites" ? "Favorites" : value.name
            row.createdAt = value.createdAt
            row.systemKind = value.systemKind
            row.legacyIDs = Array(Set((row.legacyIDs ?? []) + (value.legacyIDs ?? []))).sorted {
                $0.uuidString < $1.uuidString
            }
        case .playlistVideo:
            let value = try SyncPayload.decode(SyncPlaylistVideoPayload.self, from: payload)
            let id = value.playlistID
            guard let parent = try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })).first
            else { return false }
            guard (parent.syncIncarnation ?? "initial") == (value.parentIncarnation ?? "initial") else { return false }
            if let parentState = try state(kind: .playlist, entityID: id.uuidString.lowercased()),
                try SyncPayload.decode(SyncEnvelope.self, from: parentState.envelopeData).isTombstone
            {
                return false
            }
            let row: PlaylistVideo
            if let existing = parent.videos.first(where: { $0.videoID == value.videoID }) {
                row = existing
            } else {
                guard parent.videos.count < PersistedMetadataPolicy.maximumVideosPerPlaylist else {
                    throw SyncStorageError.capacityExceeded("playlist size")
                }
                try requireCapacity(
                    PlaylistVideo.self, maximum: PersistedMetadataPolicy.maximumPlaylistVideos,
                    label: "playlist videos", playlistVideo: true)
                row = PlaylistVideo(videoID: value.videoID, title: value.title)
                row.playlist = parent
                context.insert(row)
            }
            row.title = value.title
            row.uploader = value.uploader
            row.thumbnailURL = value.thumbnailURL
            row.duration = value.duration
            row.addedAt = value.addedAt
        case .feedback:
            let value = try SyncPayload.decode(SyncFeedbackPayload.self, from: payload)
            let existing = try context.fetch(
                FetchDescriptor<Feedback>(predicate: #Predicate { $0.videoID == entityID })
            ).first
            let row: Feedback
            if let existing {
                row = existing
            } else {
                try requireCapacity(Feedback.self, maximum: PersistedMetadataPolicy.maximumFeedback, label: "feedback")
                row = Feedback(videoID: entityID, signal: value.signal, title: value.title)
                context.insert(row)
            }
            row.signal = value.signal
            row.title = value.title
            row.uploader = value.uploader
            row.category = value.category
            row.tags = value.tags
            row.createdAt = value.createdAt
        case .search:
            let value = try SyncPayload.decode(SyncSearchPayload.self, from: payload)
            let existing = try context.fetch(
                FetchDescriptor<SearchEntry>(predicate: #Predicate { $0.query == entityID })
            ).first
            let row: SearchEntry
            if let existing {
                row = existing
            } else {
                try requireCapacity(
                    SearchEntry.self, maximum: PersistedMetadataPolicy.maximumSearches, label: "searches")
                row = SearchEntry(query: value.query)
                context.insert(row)
            }
            row.displayQuery = value.displayQuery
            row.lastSearchedAt = value.lastSearchedAt
            row.count = value.count
        case .preference:
            let value = try SyncPayload.decode(SyncPreferencePayload.self, from: payload)
            let existing = try context.fetch(
                FetchDescriptor<SyncPreference>(predicate: #Predicate { $0.key == entityID })
            ).first
            let isExplicit = value.isExplicit ?? true
            if let existing {
                existing.value = value.value
                existing.modifiedAt = value.modifiedAt
                existing.isExplicit = isExplicit
            } else {
                context.insert(
                    SyncPreference(
                        key: value.key, value: value.value, isExplicit: isExplicit, modifiedAt: value.modifiedAt))
            }
        case .policy:
            try applyCategoryPolicy(SyncPayload.decode(SyncCategoryPolicy.self, from: payload))
        case .activity, .impressionBaseline:
            try RecommendationSyncBridge.apply(
                kind: kind, entityID: entityID, payload: payload, in: context,
                rebuildProjection: rebuildActivityProjection)
        }
        return true
    }

    private func deleteMaterialized(kind: SyncKind, entityID: String) throws {
        switch kind {
        case .subscription:
            for row in try context.fetch(
                FetchDescriptor<SubscribedChannel>(predicate: #Predicate { $0.channelID == entityID }))
            { context.delete(row) }
        case .history:
            for row in try context.fetch(
                FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == entityID }))
            { context.delete(row) }
        case .playlist:
            guard let id = UUID(uuidString: entityID) else { throw SyncStorageError.invalidPayload }
            let parents = try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id }))
            let deletedIncarnation =
                try state(kind: .playlist, entityID: entityID)?.playlistIncarnation
                ?? parents.first.map { $0.syncIncarnation ?? "initial" }
            for row in parents { context.delete(row) }
            // An encrypted tombstone proves only this incarnation is gone. Future-incarnation
            // children may already be staged ahead of their restored parent.
            let namespace = try currentNamespace()
            let childKind = SyncKind.playlistVideo.rawValue
            for row in try context.fetch(
                FetchDescriptor<SyncRecordState>(
                    predicate: #Predicate { $0.namespace == namespace && $0.kindRawValue == childKind }))
            where row.entityID.hasPrefix(entityID + ":") {
                let child = try SyncPayload.decode(SyncEnvelope.self, from: row.envelopeData)
                guard let data = child.effectivePayload else { continue }
                let member = try SyncPayload.decode(SyncPlaylistVideoPayload.self, from: data)
                if deletedIncarnation == (member.parentIncarnation ?? "initial") {
                    try markObsolete(row, envelope: child)
                }
            }
        case .playlistVideo:
            let parts = entityID.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let id = UUID(uuidString: parts[0]) else { throw SyncStorageError.invalidPayload }
            let videoID = parts.last!
            if let parent = try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })).first,
                (parent.syncIncarnation ?? "initial") == parts[1]
            {
                for row in parent.videos.filter({ $0.videoID == videoID }) {
                    parent.videos.removeAll { $0 === row }
                    context.delete(row)
                }
            }
        case .feedback:
            for row in try context.fetch(FetchDescriptor<Feedback>(predicate: #Predicate { $0.videoID == entityID })) {
                context.delete(row)
            }
        case .search:
            for row in try context.fetch(FetchDescriptor<SearchEntry>(predicate: #Predicate { $0.query == entityID })) {
                context.delete(row)
            }
        case .preference:
            for row in try context.fetch(FetchDescriptor<SyncPreference>(predicate: #Predicate { $0.key == entityID }))
            { context.delete(row) }
        case .activity, .impressionBaseline:
            try RecommendationSyncBridge.apply(
                kind: kind, entityID: entityID, payload: nil, in: context, rebuildProjection: rebuildActivityProjection)
        case .policy:
            throw SyncStorageError.invalidPayload
        }
    }

    private func deleteAllMaterialized(kind: SyncKind) throws {
        switch kind {
        case .subscription: for row in try context.fetch(FetchDescriptor<SubscribedChannel>()) { context.delete(row) }
        case .history: for row in try context.fetch(FetchDescriptor<HistoryEntry>()) { context.delete(row) }
        case .playlist: for row in try context.fetch(FetchDescriptor<Playlist>()) { context.delete(row) }
        case .playlistVideo:
            for row in try context.fetch(FetchDescriptor<PlaylistVideo>()) {
                row.playlist?.videos.removeAll { $0 === row }
                context.delete(row)
            }
        case .feedback: for row in try context.fetch(FetchDescriptor<Feedback>()) { context.delete(row) }
        case .search: for row in try context.fetch(FetchDescriptor<SearchEntry>()) { context.delete(row) }
        case .activity, .impressionBaseline: try RecommendationSyncBridge.reset(kind: kind, in: context)
        case .preference, .policy: throw SyncStorageError.unsupportedKind
        }
    }
}
