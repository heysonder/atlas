import Foundation

nonisolated enum SyncMergePolicy {
    /// Projection never replaces register versions. A subsequent local mutation observes the
    /// full frontier and carries forward the projected domain state in its new payload.
    static func projectedPayload(for envelope: SyncEnvelope) throws -> Data? {
        guard !envelope.register.isTombstone else { return nil }
        let payloads = envelope.register.versions.compactMap(\.payload)
        guard payloads.count > 1 else { return payloads.first }
        switch envelope.kind {
        case .search:
            return try SyncSearchPayload.mergedPayloads(payloads)
        case .history:
            return try SyncHistoryPayload.mergedPayloads(payloads)
        case .activity, .impressionBaseline:
            return try RecommendationSyncBridge.mergedPayloads(
                kind: envelope.kind, entityID: envelope.entityID, payloads: payloads)
                ?? envelope.register.effectivePayload
        default:
            return envelope.register.effectivePayload
        }
    }

    /// Join of two observed-remove registers. An absent version is a removal only when the
    /// other replica's causal context says it has actually observed that version.
    static func merge(_ lhs: SyncEnvelope, _ rhs: SyncEnvelope) throws -> SyncEnvelope {
        try lhs.validate()
        try rhs.validate()
        guard lhs.kind == rhs.kind, lhs.entityID == rhs.entityID else {
            throw SyncProtocolError.mismatchedEntity
        }
        guard lhs.generation == rhs.generation else { throw SyncProtocolError.mismatchedGeneration }

        let left = Dictionary(uniqueKeysWithValues: lhs.register.versions.map { ($0.dot, $0) })
        let right = Dictionary(uniqueKeysWithValues: rhs.register.versions.map { ($0.dot, $0) })
        var frontier: [SyncRegisterVersion] = []
        for (dot, version) in left {
            if let counterpart = right[dot] {
                // Reusing a writer/counter for another value is corruption, not a conflict.
                guard version == counterpart else { throw SyncProtocolError.invalidCausalState }
                frontier.append(version)
            } else if !rhs.register.context.contains(dot) {
                frontier.append(version)
            }
        }
        for (dot, version) in right where left[dot] == nil {
            if !lhs.register.context.contains(dot) { frontier.append(version) }
        }
        frontier.sort {
            if $0.dot.counter != $1.dot.counter { return $0.dot.counter < $1.dot.counter }
            return $0.dot.installationID < $1.dot.installationID
        }
        var context = lhs.register.context
        for (writer, counter) in rhs.register.context.counters {
            context[writer] = max(context[writer], counter)
        }
        let result = SyncEnvelope(
            kind: lhs.kind, entityID: lhs.entityID, generation: lhs.generation,
            register: SyncRegister(context: context, versions: frontier))
        try result.validate()
        return result
    }
}
