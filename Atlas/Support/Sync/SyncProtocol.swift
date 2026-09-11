import Foundation

/// Application values are encoded inside one encrypted CloudKit bytes field.
/// Record names and other CloudKit service metadata are deliberately not values in this protocol.
nonisolated enum SyncKind: String, Codable, CaseIterable, Sendable {
    case subscription
    case history
    case playlist
    case playlistVideo
    case feedback
    case search
    case preference
    case activity
    case impressionBaseline
    case policy
}

nonisolated enum SyncProtocolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion
    case oversizedPayload
    case invalidPayload
    case invalidIdentity
    case invalidCausalState
    case causalCapacityExceeded
    case mismatchedEntity
    case mismatchedGeneration
    case plaintextField
    case unexpectedField
    case unexpectedRecord
    case invalidSystemFields

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This iCloud library requires a newer version of Atlas."
        case .oversizedPayload: "An item exceeds Atlas’s iCloud sync size limit. Your local data is preserved."
        case .invalidPayload: "An iCloud item could not be read safely. Your local data is preserved."
        case .invalidIdentity: "An iCloud item has an invalid identity."
        case .invalidCausalState: "An iCloud item has inconsistent change history."
        case .causalCapacityExceeded: "An iCloud item exceeds Atlas’s supported change history."
        case .mismatchedEntity: "The iCloud items refer to different library entries."
        case .mismatchedGeneration: "The iCloud items belong to different library generations."
        case .plaintextField: "An iCloud item contains an unencrypted application field. Sync is paused."
        case .unexpectedField: "An iCloud item contains fields this version of Atlas does not support."
        case .unexpectedRecord: "An iCloud item does not match its expected record identity."
        case .invalidSystemFields: "The saved iCloud record metadata could not be restored."
        }
    }
}

nonisolated struct SyncDot: Codable, Hashable, Sendable {
    var installationID: String
    var counter: UInt64
}

/// A counter means this replica has observed every earlier mutation from that installation.
/// Writers must persist their counter with the materialized change and must never reuse a dot.
nonisolated struct SyncVersionVector: Codable, Equatable, Sendable {
    var counters: [String: UInt64] = [:]

    subscript(installationID: String) -> UInt64 {
        get { counters[installationID, default: 0] }
        set { counters[installationID] = newValue }
    }

    func contains(_ dot: SyncDot) -> Bool { self[dot.installationID] >= dot.counter }
}

nonisolated struct SyncRegisterVersion: Codable, Equatable, Sendable {
    var dot: SyncDot
    /// A nil value is a deletion, rather than a missing or undecodable record.
    var payload: Data?
    var modifiedAt: Date
}

/// An observed-remove, multi-value register. All concurrent versions remain in the frontier,
/// even when a deterministic presentation rule chooses just one of them for the local model.
nonisolated struct SyncRegister: Codable, Equatable, Sendable {
    var context: SyncVersionVector
    var versions: [SyncRegisterVersion]

    var effectiveVersion: SyncRegisterVersion? {
        let removals = versions.filter { $0.payload == nil }
        return (removals.isEmpty ? versions : removals).max { lhs, rhs in
            if lhs.dot.counter != rhs.dot.counter { return lhs.dot.counter < rhs.dot.counter }
            return lhs.dot.installationID < rhs.dot.installationID
        }
    }

    var effectivePayload: Data? { effectiveVersion?.payload }
    var isTombstone: Bool { effectiveVersion?.payload == nil }
}

nonisolated struct SyncEnvelope: Codable, Equatable, Sendable {
    /// Bump this before adding/changing domain DTO fields unless every older writer can preserve
    /// them. Version 1 domain DTOs are closed schemas; they are not a feature-extension channel.
    static let currentSchemaVersion = 1
    var schemaVersion: Int = currentSchemaVersion
    var kind: SyncKind
    var entityID: String
    var generation: String = "initial"
    var register: SyncRegister

    /// Only read after validation (decoding and mutation boundaries validate before persistence).
    /// Domain projections preserve monotone counters/taps without collapsing the causal frontier.
    var effectivePayload: Data? { try? SyncMergePolicy.projectedPayload(for: self) }
    var isTombstone: Bool { register.isTombstone }

    /// The caller allocates a monotonically increasing installation counter in its save transaction.
    /// A new local action observes the entire previous frontier, including concurrent removals.
    static func mutation(
        kind: SyncKind,
        entityID: String,
        generation: String = "initial",
        from prior: SyncEnvelope? = nil,
        payload: Data?,
        writerID: String,
        counter: UInt64,
        date: Date = Date()
    ) throws -> SyncEnvelope {
        if let prior {
            try prior.validate()
            guard prior.kind == kind, prior.entityID == entityID else {
                throw SyncProtocolError.mismatchedEntity
            }
            guard prior.generation == generation else { throw SyncProtocolError.mismatchedGeneration }
        }
        var context = prior?.register.context ?? SyncVersionVector()
        guard counter > context[writerID] else { throw SyncProtocolError.invalidCausalState }
        context[writerID] = counter
        let result = SyncEnvelope(
            kind: kind, entityID: entityID, generation: generation,
            register: SyncRegister(
                context: context,
                versions: [
                    SyncRegisterVersion(
                        dot: SyncDot(installationID: writerID, counter: counter),
                        payload: payload, modifiedAt: date)
                ]))
        try result.validate()
        return result
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw SyncProtocolError.unsupportedVersion }
        guard !entityID.isEmpty, entityID.utf8.count <= 2_048,
            !generation.isEmpty, generation.utf8.count <= 128
        else {
            throw SyncProtocolError.invalidIdentity
        }
        guard !register.versions.isEmpty else { throw SyncProtocolError.invalidCausalState }
        guard register.context.counters.count <= SyncPayload.maximumWriters,
            register.versions.count <= SyncPayload.maximumWriters
        else {
            throw SyncProtocolError.causalCapacityExceeded
        }
        for (writer, counter) in register.context.counters {
            guard !writer.isEmpty, writer.utf8.count <= 128, counter > 0 else {
                throw SyncProtocolError.invalidCausalState
            }
        }
        var dots = Set<SyncDot>()
        var frontierWriters = Set<String>()
        for version in register.versions {
            guard version.dot.counter > 0,
                register.context[version.dot.installationID] == version.dot.counter,
                dots.insert(version.dot).inserted,
                frontierWriters.insert(version.dot.installationID).inserted,
                version.modifiedAt.timeIntervalSinceReferenceDate.isFinite
            else {
                throw SyncProtocolError.invalidCausalState
            }
            if let payload = version.payload { try SyncPayload.validateJSON(payload) }
        }
        if let projected = try SyncMergePolicy.projectedPayload(for: self) {
            try SyncPayload.validateJSON(projected)
        }
        // This also bounds the base64 expansion of opaque payload bytes and causal metadata.
        _ = try SyncPayload.encode(self)
    }
}

nonisolated enum SyncPayload {
    static let maximumBytes = 128 * 1_024
    static let maximumWriters = 128
    static let maximumCollectionElements = 4_096
    static let maximumNestingDepth = 32

    static func encode<T: Encodable & Sendable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw SyncProtocolError.oversizedPayload }
        return data
    }

    static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        try validateJSON(data)
        do { return try JSONDecoder().decode(type, from: data) } catch { throw SyncProtocolError.invalidPayload }
    }

    static func validateJSON(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw SyncProtocolError.oversizedPayload }
        // Reject extreme nesting before Foundation allocates an object graph. Strings can contain
        // brackets; only unquoted delimiters contribute to the structural depth.
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in data {
            if quoted {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    quoted = false
                }
            } else if byte == 0x22 {
                quoted = true
            } else if byte == 0x7B || byte == 0x5B {
                depth += 1
                guard depth <= maximumNestingDepth else { throw SyncProtocolError.invalidPayload }
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
                guard depth >= 0 else { throw SyncProtocolError.invalidPayload }
            }
        }
        guard depth == 0, !quoted else { throw SyncProtocolError.invalidPayload }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
            throw SyncProtocolError.invalidPayload
        }
        try validateCollections(value)
    }

    private static func validateCollections(_ value: Any) throws {
        if let array = value as? [Any] {
            guard array.count <= maximumCollectionElements else { throw SyncProtocolError.invalidPayload }
            for item in array { try validateCollections(item) }
        } else if let object = value as? [String: Any] {
            guard object.count <= maximumCollectionElements else { throw SyncProtocolError.invalidPayload }
            for item in object.values { try validateCollections(item) }
        }
    }
}
