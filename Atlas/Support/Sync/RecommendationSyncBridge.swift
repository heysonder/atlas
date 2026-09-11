import Foundation
import SwiftData

nonisolated struct RecommendationSyncFeatures: Codable, Equatable, Sendable {
    var topicSimilarity: Double
    var longTermSimilarity: Double
    var categoryFit: Double
    var corroboration: Int
    var freshness: Double
    var channelAffinity: Double
    var isSubscribed: Bool
    var dislikeSimilarity: Double
    var priorImpressions: Int
    var fromRelated: Bool
    var fromSearch: Bool
    var fromSaved: Bool
    var fromSubscription: Bool
    var fromExploration: Bool
    var usedContextualEmbedding: Bool

    init(_ source: RecommendationOutcomeFeatures) {
        topicSimilarity = source.topicSimilarity
        longTermSimilarity = source.longTermSimilarity
        categoryFit = source.categoryFit
        corroboration = source.corroboration
        freshness = source.freshness
        channelAffinity = source.channelAffinity
        isSubscribed = source.isSubscribed
        dislikeSimilarity = source.dislikeSimilarity
        priorImpressions = source.priorImpressions
        fromRelated = source.fromRelated
        fromSearch = source.fromSearch
        fromSaved = source.fromSaved
        fromSubscription = source.fromSubscription
        fromExploration = source.fromExploration
        usedContextualEmbedding = source.usedContextualEmbedding
    }

    @MainActor init(_ source: RecommendationOutcomeEntry) {
        topicSimilarity = source.topicSimilarity
        longTermSimilarity = source.longTermSimilarity
        categoryFit = source.categoryFit
        corroboration = source.corroboration
        freshness = source.freshness
        channelAffinity = source.channelAffinity
        isSubscribed = source.isSubscribed
        dislikeSimilarity = source.dislikeSimilarity
        priorImpressions = source.priorImpressions
        fromRelated = source.fromRelated
        fromSearch = source.fromSearch
        fromSaved = source.fromSaved
        fromSubscription = source.fromSubscription
        fromExploration = source.fromExploration
        usedContextualEmbedding = source.usedContextualEmbedding
    }

    var features: RecommendationOutcomeFeatures {
        RecommendationOutcomeFeatures(
            topicSimilarity: topicSimilarity,
            longTermSimilarity: longTermSimilarity,
            categoryFit: categoryFit,
            corroboration: corroboration,
            freshness: freshness,
            channelAffinity: channelAffinity,
            isSubscribed: isSubscribed,
            dislikeSimilarity: dislikeSimilarity,
            priorImpressions: priorImpressions,
            fromRelated: fromRelated,
            fromSearch: fromSearch,
            fromSaved: fromSaved,
            fromSubscription: fromSubscription,
            fromExploration: fromExploration,
            usedContextualEmbedding: usedContextualEmbedding)
    }

    var isValid: Bool {
        let similarities = [topicSimilarity, longTermSimilarity, dislikeSimilarity]
        let fractions = [categoryFit, freshness, channelAffinity]
        return similarities.allSatisfy { $0.isFinite && (-1.001...1.001).contains($0) }
            && fractions.allSatisfy { $0.isFinite && (0...1.001).contains($0) }
            && (0...1_000_000).contains(corroboration)
            && (0...12).contains(priorImpressions)
    }

    static var empty: Self {
        Self(
            RecommendationOutcomeFeatures(
                topicSimilarity: 0,
                longTermSimilarity: 0,
                categoryFit: 0,
                corroboration: 0,
                freshness: 0,
                channelAffinity: 0,
                isSubscribed: false,
                dislikeSimilarity: 0,
                priorImpressions: 0,
                fromRelated: false,
                fromSearch: false,
                fromSaved: false,
                fromSubscription: false,
                fromExploration: false,
                usedContextualEmbedding: false))
    }
}

nonisolated struct RecommendationActivityPayload: Codable, Equatable, Sendable {
    var eventID: UUID
    var originID: String
    var videoID: String
    var shownAt: Date
    var position: Int
    var tappedAt: Date?
    var featureSchemaVersion: Int
    var contributesToImpressions: Bool
    var features: RecommendationSyncFeatures

    private enum CodingKeys: String, CodingKey {
        case eventID, originID, videoID, shownAt, position, tappedAt
        case featureSchemaVersion, contributesToImpressions, features
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try values.decode(UUID.self, forKey: .eventID)
        originID = try values.decode(String.self, forKey: .originID)
        videoID = try values.decode(String.self, forKey: .videoID)
        shownAt = try values.decode(Date.self, forKey: .shownAt)
        position = try values.decode(Int.self, forKey: .position)
        tappedAt = try values.decodeIfPresent(Date.self, forKey: .tappedAt)
        featureSchemaVersion = try values.decode(Int.self, forKey: .featureSchemaVersion)
        contributesToImpressions = try values.decode(Bool.self, forKey: .contributesToImpressions)
        if featureSchemaVersion <= 1 {
            features = try values.decode(RecommendationSyncFeatures.self, forKey: .features)
        } else {
            // A future feature layout may have completely different fields.
            // Preserve its bounded JSON in the model; it cannot train this app.
            guard values.contains(.features) else { throw SyncProtocolError.invalidPayload }
            features = .empty
        }
    }

    @MainActor init(_ row: RecommendationOutcomeEntry) throws {
        guard let id = row.eventID else { throw SyncProtocolError.invalidIdentity }
        eventID = id
        originID = row.originID
        videoID = row.videoID
        shownAt = row.shownAt
        position = row.position
        tappedAt = row.tapped ? row.tappedAt : nil
        featureSchemaVersion = row.featureSchemaVersion
        contributesToImpressions = row.contributesToImpressions
        features = RecommendationSyncFeatures(row)
    }

    func validate(entityID: String, now: Date = .now) throws {
        guard eventID.uuidString.lowercased() == entityID.lowercased(),
            !originID.isEmpty, originID.utf8.count <= 128,
            !videoID.isEmpty, videoID.utf8.count <= PersistedMetadataPolicy.maximumIdentifierBytes,
            (0..<20_000).contains(position),
            (0...1_000_000).contains(featureSchemaVersion),
            features.isValid,
            Self.validDate(shownAt, now: now),
            tappedAt.map({ Self.validDate($0, now: now) && $0 >= shownAt }) ?? true
        else { throw SyncProtocolError.invalidPayload }
    }

    static func validDate(_ date: Date, now: Date) -> Bool {
        date.timeIntervalSince1970.isFinite
            && date >= Date(timeIntervalSince1970: 0)
            && date <= now.addingTimeInterval(86_400)
    }
}

nonisolated struct RecommendationBaselinePayload: Codable, Equatable, Sendable {
    var id: UUID
    var videoID: String
    var count: Int
    var lastShownAt: Date

    func validate(entityID: String, now: Date = .now) throws {
        guard id.uuidString.lowercased() == entityID.lowercased(),
            !videoID.isEmpty, videoID.utf8.count <= PersistedMetadataPolicy.maximumIdentifierBytes,
            (0...12).contains(count),
            RecommendationActivityPayload.validDate(lastShownAt, now: now)
        else { throw SyncProtocolError.invalidPayload }
    }
}

nonisolated struct RecommendationRetentionPayload: Codable, Equatable, Sendable {
    var cutoff: Date
    /// All events at this time up to and including this UUID have expired.
    /// Empty means strictly earlier dates only (the age-based cutoff).
    var eventID: String

    func validate(now: Date = .now) throws {
        guard RecommendationActivityPayload.validDate(cutoff, now: now),
            eventID.isEmpty || UUID(uuidString: eventID) != nil
        else { throw SyncProtocolError.invalidPayload }
    }

    func contains(date: Date, id: UUID) -> Bool {
        date < cutoff || (date == cutoff && id.uuidString.lowercased() <= eventID)
    }

    func precedes(_ other: Self) -> Bool {
        cutoff == other.cutoff ? eventID < other.eventID : cutoff < other.cutoff
    }
}

/// Encodes recommendation inputs only. Ranking profiles and aggregate counters
/// are projections rebuilt on each device after a durable incoming batch.
@MainActor
enum RecommendationSyncBridge {
    nonisolated static let retentionEntityID = "retention"
    static let maximumRows = 20_000
    static let maximumAge: TimeInterval = 180 * 86_400

    @discardableResult
    static func prepare(in context: ModelContext) throws -> RecommendationActivityState {
        let state: RecommendationActivityState
        if let existing = try context.fetch(FetchDescriptor<RecommendationActivityState>()).first {
            state = existing
        } else {
            state = RecommendationActivityState()
            context.insert(state)
        }
        guard !state.migrated else { return state }
        // Preserve each old aggregate once. Historical outcome rows get stable
        // IDs but their default contributesToImpressions remains false.
        for row in try context.fetch(FetchDescriptor<FeedImpressionEntry>()) {
            guard row.count > 0, !row.videoID.isEmpty else { continue }
            context.insert(
                FeedImpressionBaseline(
                    videoID: row.videoID, count: min(12, row.count), lastShownAt: row.lastShownAt))
        }
        for row in try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>()) {
            if row.eventID == nil { row.eventID = UUID() }
            if row.originID == "legacy" { row.originID = state.originID }
            if row.tappedAt.map({ $0 >= Date().addingTimeInterval(-FeedImpressionStore.maximumAge) }) ?? false {
                try recordTapReset(for: row, in: context)
            }
        }
        state.migrated = true
        return state
    }

    /// The reset outlives an old event near the training-log cutoff, while
    /// remaining bounded to the same 45-day window as impression penalties.
    static func recordTapReset(for event: RecommendationOutcomeEntry, in context: ModelContext) throws {
        guard let id = event.eventID, event.tapped, let tappedAt = event.tappedAt else { return }
        let existing = try context.fetch(FetchDescriptor<FeedImpressionBaseline>(predicate: #Predicate { $0.id == id }))
            .first
        if let existing {
            guard existing.videoID == event.videoID, existing.count == 0 else { throw SyncProtocolError.invalidPayload }
            existing.lastShownAt = max(existing.lastShownAt, tappedAt)
        } else {
            context.insert(FeedImpressionBaseline(id: id, videoID: event.videoID, count: 0, lastShownAt: tappedAt))
        }
    }

    static func snapshots(
        in context: ModelContext, kind: SyncKind? = nil, entityID: String? = nil
    ) throws -> [(kind: SyncKind, entityID: String, payload: Data)] {
        let state = try prepare(in: context)
        var values: [(kind: SyncKind, entityID: String, payload: Data)] = []
        if kind == nil || kind == .activity {
            if entityID != retentionEntityID {
                let requestedID = entityID.flatMap(UUID.init(uuidString:))
                let descriptor =
                    entityID == nil
                    ? FetchDescriptor<RecommendationOutcomeEntry>()
                    : FetchDescriptor<RecommendationOutcomeEntry>(predicate: #Predicate { $0.eventID == requestedID })
                for row in try context.fetch(descriptor) {
                    let payload = try RecommendationActivityPayload(row)
                    let id = payload.eventID.uuidString.lowercased()
                    try payload.validate(entityID: id)
                    let encoded: Data
                    if let original = row.unrecognizedSyncPayload, row.featureSchemaVersion > 1 {
                        encoded = try updatingTap(original, tappedAt: row.tapped ? row.tappedAt : nil)
                    } else {
                        encoded = try SyncPayload.encode(payload)
                    }
                    values.append((.activity, id, encoded))
                }
            }
            if entityID == nil || entityID == retentionEntityID {
                values.append(
                    (
                        .activity, retentionEntityID,
                        try SyncPayload.encode(
                            RecommendationRetentionPayload(
                                cutoff: state.retentionCutoff, eventID: state.retentionEventID))
                    ))
            }
        }
        if kind == nil || kind == .impressionBaseline {
            let requestedID = entityID.flatMap(UUID.init(uuidString:)) ?? UUID()
            let descriptor =
                entityID == nil
                ? FetchDescriptor<FeedImpressionBaseline>()
                : FetchDescriptor<FeedImpressionBaseline>(predicate: #Predicate { $0.id == requestedID })
            for row in try context.fetch(descriptor) {
                let payload = RecommendationBaselinePayload(
                    id: row.id, videoID: row.videoID, count: row.count, lastShownAt: row.lastShownAt)
                let id = row.id.uuidString.lowercased()
                try payload.validate(entityID: id)
                values.append((.impressionBaseline, id, try SyncPayload.encode(payload)))
            }
        }
        return values
    }

    /// Used by the adapter's post-fetch cleanup pass as well as materialization.
    /// Rejected old uploads must become pending cloud deletions, not merely be
    /// hidden from the current device's recommendation counts.
    static func retentionBarrier(in context: ModelContext) throws -> RecommendationRetentionPayload {
        let state = try prepare(in: context)
        return RecommendationRetentionPayload(cutoff: state.retentionCutoff, eventID: state.retentionEventID)
    }

    static func shouldRetain(
        kind: SyncKind, entityID: String, payload: Data, in context: ModelContext, now: Date = .now
    ) throws -> Bool {
        try shouldRetain(
            kind: kind, entityID: entityID, payload: payload, barrier: retentionBarrier(in: context), now: now)
    }

    /// The barrier-taking variant lets a batch pass fetch the state once per batch.
    static func shouldRetain(
        kind: SyncKind, entityID: String, payload: Data, barrier: RecommendationRetentionPayload, now: Date = .now
    ) throws -> Bool {
        if kind == .activity, entityID == retentionEntityID { return true }
        if kind == .activity {
            let value = try SyncPayload.decode(RecommendationActivityPayload.self, from: payload)
            try value.validate(entityID: entityID, now: now)
            return !barrier.contains(date: value.shownAt, id: value.eventID)
                && value.shownAt >= now.addingTimeInterval(-maximumAge)
        }
        if kind == .impressionBaseline {
            let value = try SyncPayload.decode(RecommendationBaselinePayload.self, from: payload)
            try value.validate(entityID: entityID, now: now)
            return value.lastShownAt >= now.addingTimeInterval(-FeedImpressionStore.maximumAge)
        }
        throw SyncProtocolError.invalidPayload
    }

    static func apply(
        kind: SyncKind, entityID: String, payload: Data?, in context: ModelContext,
        rebuildProjection: Bool = true
    ) throws {
        let state = try prepare(in: context)
        if kind == .activity, entityID == retentionEntityID {
            guard let payload else { throw SyncProtocolError.invalidPayload }
            let cutoff = try SyncPayload.decode(RecommendationRetentionPayload.self, from: payload)
            try cutoff.validate()
            let current = RecommendationRetentionPayload(cutoff: state.retentionCutoff, eventID: state.retentionEventID)
            if current.precedes(cutoff) {
                state.retentionCutoff = cutoff.cutoff
                state.retentionEventID = cutoff.eventID
            }
            try prune(in: context, journalDeletions: false)
        } else if kind == .activity {
            guard let id = UUID(uuidString: entityID) else { throw SyncProtocolError.invalidIdentity }
            let optionalID: UUID? = id
            let rows = try context.fetch(
                FetchDescriptor<RecommendationOutcomeEntry>(
                    predicate: #Predicate { $0.eventID == optionalID }))
            if let payload {
                let value = try SyncPayload.decode(RecommendationActivityPayload.self, from: payload)
                try value.validate(entityID: entityID)
                let barrier = RecommendationRetentionPayload(
                    cutoff: state.retentionCutoff, eventID: state.retentionEventID)
                guard !barrier.contains(date: value.shownAt, id: value.eventID),
                    value.shownAt >= Date().addingTimeInterval(-maximumAge)
                else {
                    for row in rows { context.delete(row) }
                    if rebuildProjection { try Self.rebuildProjection(in: context) }
                    return
                }
                if let row = rows.first {
                    // Creation features are immutable; the pure frontier merger
                    // rejects any conflicting content for an existing event ID.
                    let previous = try RecommendationActivityPayload(row)
                    let previousData = try row.unrecognizedSyncPayload ?? SyncPayload.encode(previous)
                    guard try creationData(previousData) == creationData(payload) else {
                        throw SyncProtocolError.invalidPayload
                    }
                    row.tappedAt = [previous.tappedAt, value.tappedAt].compactMap { $0 }.max()
                    row.tapped = row.tappedAt != nil
                    if value.featureSchemaVersion > 1 {
                        row.unrecognizedSyncPayload = try updatingTap(payload, tappedAt: row.tappedAt)
                    }
                } else {
                    let row = RecommendationOutcomeEntry(
                        videoID: value.videoID, shownAt: value.shownAt,
                        position: value.position, features: value.features.features,
                        eventID: value.eventID, originID: value.originID,
                        featureSchemaVersion: value.featureSchemaVersion,
                        contributesToImpressions: value.contributesToImpressions)
                    row.tappedAt = value.tappedAt
                    row.tapped = value.tappedAt != nil
                    if value.featureSchemaVersion > 1 { row.unrecognizedSyncPayload = payload }
                    context.insert(row)
                }
            } else {
                for row in rows { context.delete(row) }
            }
        } else if kind == .impressionBaseline {
            guard let id = UUID(uuidString: entityID) else { throw SyncProtocolError.invalidIdentity }
            let rows = try context.fetch(FetchDescriptor<FeedImpressionBaseline>(predicate: #Predicate { $0.id == id }))
            if let payload {
                let value = try SyncPayload.decode(RecommendationBaselinePayload.self, from: payload)
                try value.validate(entityID: entityID)
                guard value.lastShownAt >= Date().addingTimeInterval(-FeedImpressionStore.maximumAge) else {
                    for row in rows { context.delete(row) }
                    if rebuildProjection { try Self.rebuildProjection(in: context) }
                    return
                }
                if let row = rows.first {
                    guard row.videoID == value.videoID, row.count == value.count else {
                        throw SyncProtocolError.invalidPayload
                    }
                    if value.count == 0 {
                        row.lastShownAt = max(row.lastShownAt, value.lastShownAt)
                    } else if row.lastShownAt != value.lastShownAt {
                        throw SyncProtocolError.invalidPayload
                    }
                } else {
                    context.insert(
                        FeedImpressionBaseline(
                            id: value.id, videoID: value.videoID, count: value.count, lastShownAt: value.lastShownAt))
                }
            } else {
                for row in rows { context.delete(row) }
            }
        } else {
            throw SyncProtocolError.invalidPayload
        }
        if rebuildProjection { try Self.rebuildProjection(in: context) }
    }

    /// Called once after a fetched batch instead of rescanning the entire event
    /// log for each arriving row during a large initial library merge.
    static func rebuildProjection(in context: ModelContext) throws {
        try FeedImpressionStore.rebuild(in: context)
        try RecommendationProfileStore.invalidate(in: context)
    }

    /// Local pruning advances a shared deterministic barrier, then tombstones
    /// evicted events. Applying remote policy suppresses old rows without making
    /// the incoming operation appear to be new user activity.
    static func prune(in context: ModelContext, now: Date = .now, journalDeletions: Bool = true) throws {
        let state = try prepare(in: context)
        var barrier = RecommendationRetentionPayload(cutoff: state.retentionCutoff, eventID: state.retentionEventID)
        // A barrier this device once advanced with a wrong clock is discarded. Other
        // devices never accepted it (they reject cutoffs beyond their own clocks), so
        // dropping it locally cannot resurrect anything they already removed.
        if barrier.cutoff > now.addingTimeInterval(86_400) {
            barrier = RecommendationRetentionPayload(cutoff: Date(timeIntervalSince1970: 0), eventID: "")
        }
        let age = RecommendationRetentionPayload(
            cutoff: max(Date(timeIntervalSince1970: 0), now.addingTimeInterval(-maximumAge)), eventID: "")
        if barrier.precedes(age) { barrier = age }
        // Common path: only rows at or before the cutoff can expire, and the row cap
        // needs the full sorted log only when the retained count actually exceeds it.
        let cutoff = barrier.cutoff
        var expired = try context.fetch(
            FetchDescriptor<RecommendationOutcomeEntry>(
                predicate: #Predicate { $0.shownAt <= cutoff }
            )
        ).filter { row in
            guard let id = row.eventID else { return false }
            return barrier.contains(date: row.shownAt, id: id)
        }
        let retainedCount = try context.fetchCount(FetchDescriptor<RecommendationOutcomeEntry>()) - expired.count
        if retainedCount > maximumRows {
            let rows = try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>()).sorted {
                if $0.shownAt != $1.shownAt { return $0.shownAt < $1.shownAt }
                return ($0.eventID?.uuidString.lowercased() ?? "") < ($1.eventID?.uuidString.lowercased() ?? "")
            }
            let retained = rows.filter {
                guard let id = $0.eventID else { return false }
                return !barrier.contains(date: $0.shownAt, id: id)
            }
            if retained.count > maximumRows, let last = retained.prefix(retained.count - maximumRows).last,
                let id = last.eventID
            {
                let cap = RecommendationRetentionPayload(cutoff: last.shownAt, eventID: id.uuidString.lowercased())
                if barrier.precedes(cap) { barrier = cap }
            }
            expired = rows.filter {
                guard let id = $0.eventID else { return false }
                return barrier.contains(date: $0.shownAt, id: id)
            }
        }
        state.retentionCutoff = barrier.cutoff
        state.retentionEventID = barrier.eventID
        // Expiry retires the journal row (a physical cloud deletion) rather than writing
        // a causal tombstone. The shared, validated retention barrier is the only thing
        // that removes an event from other devices, so a device with a skewed clock can
        // at most collect its own view of the cloud, never delete another device's rows.
        for row in expired {
            guard let id = row.eventID else { continue }
            if journalDeletions {
                try LibrarySyncJournal.retire(kind: .activity, entityID: id.uuidString.lowercased(), in: context)
            }
            context.delete(row)
        }
        let baselineCutoff = now.addingTimeInterval(-FeedImpressionStore.maximumAge)
        for row in try context.fetch(
            FetchDescriptor<FeedImpressionBaseline>(
                predicate: #Predicate { $0.lastShownAt < baselineCutoff }
            ))
        {
            if journalDeletions {
                try LibrarySyncJournal.retire(
                    kind: .impressionBaseline, entityID: row.id.uuidString.lowercased(), in: context)
            }
            context.delete(row)
        }
    }

    /// Clears one received category generation without deleting newer rows in
    /// another category whose policy may arrive in a later CloudKit page.
    static func reset(kind: SyncKind, in context: ModelContext) throws {
        let state = try prepare(in: context)
        switch kind {
        case .activity:
            for row in try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>()) { context.delete(row) }
            state.retentionCutoff = Date(timeIntervalSince1970: 0)
            state.retentionEventID = ""
        case .impressionBaseline:
            for row in try context.fetch(FetchDescriptor<FeedImpressionBaseline>()) { context.delete(row) }
        default:
            throw SyncProtocolError.invalidPayload
        }
        try FeedImpressionStore.rebuild(in: context)
        try RecommendationProfileStore.invalidate(in: context)
    }

    static func reset(in context: ModelContext) throws {
        try reset(kind: .activity, in: context)
        try reset(kind: .impressionBaseline, in: context)
    }

    /// Concurrent copies retain the immutable event and union positive taps.
    /// The register keeps causal history; this only computes its projection.
    nonisolated static func mergedPayloads(
        kind: SyncKind, entityID: String, payloads: [Data]
    ) throws -> Data? {
        guard let first = payloads.first else { return nil }
        if kind == .activity, entityID == retentionEntityID {
            let cutoffs = try payloads.map { try SyncPayload.decode(RecommendationRetentionPayload.self, from: $0) }
            for cutoff in cutoffs { try cutoff.validate() }
            guard let latest = cutoffs.max(by: { $0.precedes($1) }) else { return nil }
            return try SyncPayload.encode(latest)
        }
        if kind == .activity {
            var result = try SyncPayload.decode(RecommendationActivityPayload.self, from: first)
            try result.validate(entityID: entityID)
            let creation = try creationData(first)
            for payload in payloads.dropFirst() {
                let other = try SyncPayload.decode(RecommendationActivityPayload.self, from: payload)
                try other.validate(entityID: entityID)
                guard try creation == creationData(payload) else { throw SyncProtocolError.invalidPayload }
                result.tappedAt = [result.tappedAt, other.tappedAt].compactMap { $0 }.max()
            }
            return try result.featureSchemaVersion > 1
                ? updatingTap(first, tappedAt: result.tappedAt)
                : SyncPayload.encode(result)
        }
        if kind == .impressionBaseline {
            var result = try SyncPayload.decode(RecommendationBaselinePayload.self, from: first)
            try result.validate(entityID: entityID)
            for payload in payloads.dropFirst() {
                let other = try SyncPayload.decode(RecommendationBaselinePayload.self, from: payload)
                try other.validate(entityID: entityID)
                guard result.id == other.id, result.videoID == other.videoID, result.count == other.count else {
                    throw SyncProtocolError.invalidPayload
                }
                if result.count == 0 {
                    result.lastShownAt = max(result.lastShownAt, other.lastShownAt)
                } else if result.lastShownAt != other.lastShownAt {
                    throw SyncProtocolError.invalidPayload
                }
            }
            return try SyncPayload.encode(result)
        }
        return nil
    }
    private nonisolated static func creationData(_ data: Data) throws -> Data {
        try SyncPayload.validateJSON(data)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncProtocolError.invalidPayload
        }
        object.removeValue(forKey: "tappedAt")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private nonisolated static func updatingTap(_ data: Data, tappedAt: Date?) throws -> Data {
        try SyncPayload.validateJSON(data)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncProtocolError.invalidPayload
        }
        if let tappedAt {
            object["tappedAt"] = tappedAt.timeIntervalSinceReferenceDate
        } else {
            object.removeValue(forKey: "tappedAt")
        }
        let result = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        try SyncPayload.validateJSON(result)
        return result
    }

}
