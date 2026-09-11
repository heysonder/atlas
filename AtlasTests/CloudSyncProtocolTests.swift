import CloudKit
import Foundation
import Testing

@testable import Atlas

private func syncTestValue(_ value: String) throws -> Data { try SyncPayload.encode(value) }

private func syncTestMutation(
    _ writer: String, _ counter: UInt64 = 1, value: String? = "value",
    from prior: SyncEnvelope? = nil
) throws -> SyncEnvelope {
    try SyncEnvelope.mutation(
        kind: .subscription, entityID: "private-channel-identity", from: prior,
        payload: try value.map(syncTestValue), writerID: writer, counter: counter,
        date: Date(timeIntervalSince1970: 1_000))
}

@Test func cloudSyncMergeIsIdempotentCommutativeAndAssociative() throws {
    let a = try syncTestMutation("a", value: "a")
    let b = try syncTestMutation("b", value: "b")
    let c = try syncTestMutation("c", value: nil)
    let ab = try SyncMergePolicy.merge(a, b)
    let bc = try SyncMergePolicy.merge(b, c)
    #expect(try SyncMergePolicy.merge(a, a) == a)
    #expect(try SyncMergePolicy.merge(a, b) == SyncMergePolicy.merge(b, a))
    #expect(try SyncMergePolicy.merge(ab, c) == SyncMergePolicy.merge(a, bc))
    #expect(try SyncMergePolicy.merge(ab, ab) == ab)
    #expect(try SyncMergePolicy.merge(ab, c).isTombstone)
}

@Test func cloudSyncConcurrentRemovalWinsAndObservedResubscribeWinsLater() throws {
    let baseline = try syncTestMutation("a", value: "baseline")
    let edit = try syncTestMutation("a", 2, value: "updated", from: baseline)
    let deletion = try syncTestMutation("b", value: nil, from: baseline)
    let concurrent = try SyncMergePolicy.merge(edit, deletion)
    #expect(concurrent.isTombstone)
    #expect(concurrent.register.versions.count == 2)
    let resubscribe = try syncTestMutation("a", 3, value: "restored", from: concurrent)
    #expect(!resubscribe.isTombstone)
    #expect(try SyncMergePolicy.merge(resubscribe, deletion) == resubscribe)
    #expect(try SyncMergePolicy.merge(resubscribe, edit) == resubscribe)
}

@Test func cloudSyncRetainsLosingConcurrentVersionsForFutureMerge() throws {
    let a = try syncTestMutation("a", value: "a")
    let b = try syncTestMutation("b", value: "b")
    let deletion = try syncTestMutation("c", value: nil)
    let all = try SyncMergePolicy.merge(SyncMergePolicy.merge(a, b), deletion)
    #expect(all.register.versions.count == 3)
    // The third replica only observed the removal. Its restoration must not erase A or B.
    let restored = try syncTestMutation("c", 2, value: "c", from: deletion)
    let joined = try SyncMergePolicy.merge(all, restored)
    #expect(joined.register.versions.count == 3)
    #expect(!joined.isTombstone)
    #expect(try SyncMergePolicy.merge(SyncMergePolicy.merge(a, b), restored) == joined)
}

@Test func cloudSyncConvergesAcrossReorderedThreeReplicaOperations() throws {
    let first = try syncTestMutation("a")
    let second = try syncTestMutation("b", from: first)
    let removed = try syncTestMutation("c", value: nil, from: first)
    let concurrent = try syncTestMutation("a", 2, value: "offline", from: first)
    let restored = try syncTestMutation("b", 2, value: "restored", from: SyncMergePolicy.merge(second, removed))
    let states = [first, second, removed, concurrent, restored]
    for a in states {
        #expect(try SyncMergePolicy.merge(a, a) == a)
        for b in states {
            #expect(try SyncMergePolicy.merge(a, b) == SyncMergePolicy.merge(b, a))
            for c in states {
                #expect(
                    try SyncMergePolicy.merge(SyncMergePolicy.merge(a, b), c)
                        == SyncMergePolicy.merge(a, SyncMergePolicy.merge(b, c)))
            }
        }
    }
}

@Test func cloudSyncDatesDoNotDefeatCausalChanges() throws {
    var earlier = try syncTestMutation("a", value: "old")
    earlier.register.versions[0].modifiedAt = Date(timeIntervalSince1970: 9_999_999)
    let later = try syncTestMutation("b", value: "new", from: earlier)
    #expect(try SyncMergePolicy.merge(earlier, later) == later)
}

@Test func cloudSyncSearchCountsMergeComponentsWithoutReplayInflation() throws {
    let first = SyncSearchPayload(
        query: "space", displayQuery: "Space",
        lastSearchedAt: Date(timeIntervalSince1970: 1_000), legacyCount: 4, components: ["a": 2])
    let second = SyncSearchPayload(
        query: "space", displayQuery: "space",
        lastSearchedAt: Date(timeIntervalSince1970: 2_000), legacyCount: 7, components: ["b": 3])
    let a = try SyncEnvelope.mutation(
        kind: .search, entityID: "space", payload: SyncPayload.encode(first),
        writerID: "a", counter: 1)
    let b = try SyncEnvelope.mutation(
        kind: .search, entityID: "space", payload: SyncPayload.encode(second),
        writerID: "b", counter: 1)
    let merged = try SyncMergePolicy.merge(a, b)
    let data = try #require(merged.effectivePayload)
    let result = try SyncPayload.decode(SyncSearchPayload.self, from: data)
    #expect(result.count == 12)
    #expect(result.legacyCount == 7)
    #expect(result.components == ["a": 2, "b": 3])
    #expect(merged.register.versions.count == 2)
    #expect(try SyncMergePolicy.merge(merged, b).effectivePayload == data)
    #expect(try SyncMergePolicy.merge(b, a).effectivePayload == data)
}

@Test func cloudSyncHistoryUsesSessionSequenceAndAllowsLowerResumePosition() throws {
    let started = Date(timeIntervalSince1970: 1_000)
    let initial = SyncHistoryPayload(
        videoID: "video", title: "Video", uploader: nil, thumbnailURL: nil,
        watchedAt: started, positionSeconds: 2_400, durationSeconds: 3_600,
        playbackSessionID: "session", playbackSessionStartedAt: started, playbackSequence: 1)
    var advanced = initial
    advanced.playbackSequence = 2
    advanced.positionSeconds = 120
    let a = try SyncEnvelope.mutation(
        kind: .history, entityID: "video", payload: SyncPayload.encode(initial),
        writerID: "a", counter: 1)
    let b = try SyncEnvelope.mutation(
        kind: .history, entityID: "video", payload: SyncPayload.encode(advanced),
        writerID: "b", counter: 1)
    let concurrent = try SyncMergePolicy.merge(a, b)
    let result = try SyncPayload.decode(SyncHistoryPayload.self, from: #require(concurrent.effectivePayload))
    #expect(result.positionSeconds == 120)
    #expect(result.durationSeconds == 3_600)
    var rewatch = initial
    rewatch.playbackSessionID = "rewatch"
    rewatch.playbackSessionStartedAt = Date(timeIntervalSince1970: 2_000)
    rewatch.positionSeconds = 5
    let c = try SyncEnvelope.mutation(
        kind: .history, entityID: "video", from: concurrent,
        payload: SyncPayload.encode(rewatch), writerID: "c", counter: 1)
    let latest = try SyncMergePolicy.merge(concurrent, c)
    #expect(
        try SyncPayload.decode(SyncHistoryPayload.self, from: #require(latest.effectivePayload)).positionSeconds == 5)
}

@Test func cloudSyncRejectsReusedDotsAndWrongEntityOrGeneration() throws {
    let a = try syncTestMutation("a")
    #expect(throws: SyncProtocolError.invalidCausalState) {
        try syncTestMutation("a", from: a)
    }
    let differentValue = try syncTestMutation("a", value: "different")
    #expect(throws: SyncProtocolError.invalidCausalState) {
        try SyncMergePolicy.merge(a, differentValue)
    }
    var otherIdentity = a
    otherIdentity.entityID = "another-channel"
    #expect(throws: SyncProtocolError.mismatchedEntity) {
        try SyncMergePolicy.merge(a, otherIdentity)
    }
    var otherGeneration = a
    otherGeneration.generation = "after-clear"
    #expect(throws: SyncProtocolError.mismatchedGeneration) {
        try SyncMergePolicy.merge(a, otherGeneration)
    }
}

@Test func cloudSyncRejectsInvalidOrUnboundedCausalMetadata() throws {
    var item = try syncTestMutation("a")
    item.register.context.counters.removeAll()
    #expect(throws: SyncProtocolError.invalidCausalState) { try item.validate() }
    item = try syncTestMutation("a")
    item.register.versions.append(item.register.versions[0])
    #expect(throws: SyncProtocolError.invalidCausalState) { try item.validate() }
    item = try syncTestMutation("a")
    for number in 0..<SyncPayload.maximumWriters { item.register.context["replica-\(number)"] = 1 }
    #expect(throws: SyncProtocolError.causalCapacityExceeded) { try item.validate() }
}

@Test func cloudSyncEncryptsEveryCustomItemAndRootValue() throws {
    let root = SyncRoot()
    let envelope = try syncTestMutation("writer-containing-private-data", value: "private-name-and-query")
    let itemRecord = try CloudRecordCodec.encode(envelope, root: root)
    let rootRecord = try CloudRecordCodec.encodeRoot(root)
    for record in [itemRecord, rootRecord] {
        // allKeys includes the encrypted field; ordinary subscripting must not expose it.
        #expect(record.allKeys().allSatisfy { record[$0] == nil })
        #expect(Set(record.encryptedValues.allKeys()) == ["payload"])
        #expect(record.encryptedValues["payload"] is Data)
    }
    #expect(try CloudRecordCodec.decode(itemRecord, root: root) == envelope)
    #expect(try CloudRecordCodec.decodeRoot(rootRecord) == root)
}

@Test func cloudSyncOpaqueNamesAreStableKeyedAndLengthDelimited() throws {
    let key = Data(repeating: 0x2A, count: 32)
    let root = SyncRoot(identityKey: key)
    let a = try syncTestMutation("a")
    let identifier = try CloudRecordCodec.recordID(for: a, root: root)
    #expect(identifier.recordName.count == 64)
    #expect(!identifier.recordName.contains(a.entityID))
    #expect(try CloudRecordCodec.recordID(for: a, root: root) == identifier)
    var changed = a
    changed.generation = "different"
    #expect(try CloudRecordCodec.recordID(for: changed, root: root) != identifier)
    var otherKey = root
    otherKey.identityKey = Data(repeating: 0x2B, count: 32)
    #expect(try CloudRecordCodec.recordID(for: a, root: otherKey) != identifier)
    var firstTuple = a
    firstTuple.generation = "a:b"
    firstTuple.entityID = "c"
    var secondTuple = a
    secondTuple.generation = "a"
    secondTuple.entityID = "b:c"
    #expect(
        try CloudRecordCodec.recordID(for: firstTuple, root: root)
            != CloudRecordCodec.recordID(for: secondTuple, root: root))
}

@Test func cloudSyncSystemFieldArchivesExcludeAllApplicationValues() throws {
    let root = SyncRoot()
    let envelope = try syncTestMutation("sensitive-writer-identity", value: "sensitive-library-content")
    let record = try CloudRecordCodec.encode(envelope, root: root)
    let archived = try CloudRecordCodec.archiveSystemFields(record)
    for marker in [envelope.entityID, "sensitive-writer-identity", "sensitive-library-content"] {
        #expect(archived.range(of: Data(marker.utf8)) == nil)
    }
    let restored = try CloudRecordCodec.restoreSystemFields(archived)
    #expect(restored.recordID == record.recordID)
    #expect(restored.allKeys().isEmpty)
    #expect(restored.encryptedValues.allKeys().isEmpty)
    #expect(
        try CloudRecordCodec.decode(CloudRecordCodec.encode(envelope, root: root, reusing: restored), root: root)
            == envelope)
}

@Test func cloudSyncRejectsPlaintextUnexpectedAndMissingFields() throws {
    let root = SyncRoot()
    let envelope = try syncTestMutation("a")
    let plaintext = try CloudRecordCodec.encode(envelope, root: root)
    plaintext["title"] = "must-never-upload" as NSString
    #expect(throws: SyncProtocolError.plaintextField) { try CloudRecordCodec.decode(plaintext, root: root) }
    #expect(throws: SyncProtocolError.plaintextField) {
        try CloudRecordCodec.encode(envelope, root: root, reusing: plaintext)
    }
    let unknown = try CloudRecordCodec.encode(envelope, root: root)
    unknown.encryptedValues["futureField"] = "unknown" as NSString
    #expect(throws: SyncProtocolError.unexpectedField) { try CloudRecordCodec.decode(unknown, root: root) }
    let missing = try CloudRecordCodec.encode(envelope, root: root)
    missing.encryptedValues["payload"] = nil
    #expect(throws: SyncProtocolError.invalidPayload) { try CloudRecordCodec.decode(missing, root: root) }
}

@Test func cloudSyncRejectsUnsupportedAndUnknownProtocolFields() throws {
    let root = SyncRoot()
    let envelope = try syncTestMutation("a")
    let record = try CloudRecordCodec.encode(envelope, root: root)
    var future = envelope
    future.schemaVersion = 2
    record.encryptedValues["payload"] = try SyncPayload.encode(future) as NSData
    #expect(throws: SyncProtocolError.unsupportedVersion) { try CloudRecordCodec.decode(record, root: root) }
    var object = try #require(JSONSerialization.jsonObject(with: SyncPayload.encode(envelope)) as? [String: Any])
    object["futureMetadata"] = true
    record.encryptedValues["payload"] = try JSONSerialization.data(withJSONObject: object) as NSData
    #expect(throws: SyncProtocolError.unexpectedField) { try CloudRecordCodec.decode(record, root: root) }
    let rootRecord = try CloudRecordCodec.encodeRoot(root)
    var futureRoot = root
    futureRoot.minimumProtocolVersion = 2
    rootRecord.encryptedValues["payload"] = try SyncPayload.encode(futureRoot) as NSData
    #expect(throws: SyncProtocolError.unsupportedVersion) { try CloudRecordCodec.decodeRoot(rootRecord) }
}

@Test func cloudSyncRejectsWrongRecordBindingAndInvalidRootKey() throws {
    let root = SyncRoot()
    let envelope = try syncTestMutation("a")
    let record = try CloudRecordCodec.encode(envelope, root: root)
    let impostor = CKRecord(
        recordType: CloudRecordCodec.itemRecordType,
        recordID: CKRecord.ID(recordName: "incorrect", zoneID: record.recordID.zoneID))
    impostor.encryptedValues["payload"] = record.encryptedValues["payload"]
    #expect(throws: SyncProtocolError.unexpectedRecord) { try CloudRecordCodec.decode(impostor, root: root) }
    var invalid = root
    invalid.identityKey = Data(repeating: 0, count: 16)
    #expect(throws: SyncProtocolError.invalidIdentity) { try CloudRecordCodec.encodeRoot(invalid) }
}

@Test func cloudSyncRejectsOversizedMalformedAndExcessivelyNestedPayloads() throws {
    let root = SyncRoot()
    let envelope = try syncTestMutation("a")
    let record = try CloudRecordCodec.encode(envelope, root: root)
    record.encryptedValues["payload"] = Data(repeating: 0x20, count: SyncPayload.maximumBytes + 1) as NSData
    #expect(throws: SyncProtocolError.oversizedPayload) { try CloudRecordCodec.decode(record, root: root) }
    record.encryptedValues["payload"] = Data("invalid-json".utf8) as NSData
    #expect(throws: SyncProtocolError.invalidPayload) { try CloudRecordCodec.decode(record, root: root) }
    let depth = SyncPayload.maximumNestingDepth + 1
    let nested = Data((String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)).utf8)
    #expect(throws: SyncProtocolError.invalidPayload) { try SyncPayload.validateJSON(nested) }
    let largeArray = try JSONEncoder().encode(Array(repeating: 0, count: SyncPayload.maximumCollectionElements + 1))
    #expect(throws: SyncProtocolError.invalidPayload) { try SyncPayload.validateJSON(largeArray) }
    // JSON brackets inside strings do not count toward structural nesting.
    try SyncPayload.validateJSON(SyncPayload.encode(String(repeating: "[", count: 64)))
}
