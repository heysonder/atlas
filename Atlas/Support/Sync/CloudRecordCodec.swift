import CloudKit
import CryptoKit
import Foundation

/// The identity key conceals enumerable entity names; it is not a separate content encryption key.
/// Content protection and key recovery are provided by CloudKit and the account's ADP setting.
nonisolated struct SyncRoot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var libraryGeneration: String
    var identityKey: Data
    var disabled: Bool
    var minimumProtocolVersion: Int

    init(
        libraryGeneration: String = UUID().uuidString.lowercased(),
        identityKey: Data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
        disabled: Bool = false,
        minimumProtocolVersion: Int = 1,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.libraryGeneration = libraryGeneration
        self.identityKey = identityKey
        self.disabled = disabled
        self.minimumProtocolVersion = minimumProtocolVersion
    }

    func validate() throws {
        guard schemaVersion == SyncEnvelope.currentSchemaVersion,
            minimumProtocolVersion > 0,
            minimumProtocolVersion <= SyncEnvelope.currentSchemaVersion
        else {
            throw SyncProtocolError.unsupportedVersion
        }
        guard UUID(uuidString: libraryGeneration) != nil,
            libraryGeneration == libraryGeneration.lowercased(), identityKey.count == 32
        else {
            throw SyncProtocolError.invalidIdentity
        }
    }
}

nonisolated enum CloudRecordCodec {
    static let payloadField = "payload"
    static let itemRecordType = "AtlasItemV1"
    static let rootRecordType = "SyncRootV1"
    static let controlZoneID = CKRecordZone.ID(zoneName: "AtlasControlV1", ownerName: CKCurrentUserDefaultName)
    static let rootRecordID = CKRecord.ID(recordName: "SyncRootV1", zoneID: controlZoneID)

    static func libraryZoneID(for root: SyncRoot) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "AtlasLibrary_" + root.libraryGeneration, ownerName: CKCurrentUserDefaultName)
    }

    static func recordID(for envelope: SyncEnvelope, root: SyncRoot) throws -> CKRecord.ID {
        try root.validate()
        try envelope.validate()
        // Length prefix every UTF-8 component, so separators inside an identity cannot collide.
        let components = ["AtlasItemV1", envelope.kind.rawValue, envelope.generation, envelope.entityID]
        var input = Data()
        for component in components {
            let bytes = Data(component.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        let signature = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: root.identityKey))
        let name = signature.map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: name, zoneID: libraryZoneID(for: root))
    }

    static func encode(_ envelope: SyncEnvelope, root: SyncRoot, reusing record: CKRecord? = nil) throws -> CKRecord {
        let identifier = try recordID(for: envelope, root: root)
        let target = record ?? CKRecord(recordType: itemRecordType, recordID: identifier)
        try validateRecord(target, type: itemRecordType, identifier: identifier, requiresPayload: false)
        target.encryptedValues[payloadField] = try SyncPayload.encode(envelope) as NSData
        return target
    }

    static func decode(_ record: CKRecord, root: SyncRoot) throws -> SyncEnvelope {
        try root.validate()
        guard record.recordID.zoneID == libraryZoneID(for: root) else {
            throw SyncProtocolError.unexpectedRecord
        }
        try validateRecord(record, type: itemRecordType, identifier: record.recordID, requiresPayload: true)
        let data = try payload(from: record)
        try validateEnvelopeShape(data)
        let envelope = try SyncPayload.decode(SyncEnvelope.self, from: data)
        try envelope.validate()
        guard record.recordID == (try recordID(for: envelope, root: root)) else {
            throw SyncProtocolError.unexpectedRecord
        }
        return envelope
    }

    static func encodeRoot(_ root: SyncRoot, reusing record: CKRecord? = nil) throws -> CKRecord {
        try root.validate()
        let target = record ?? CKRecord(recordType: rootRecordType, recordID: rootRecordID)
        try validateRecord(target, type: rootRecordType, identifier: rootRecordID, requiresPayload: false)
        target.encryptedValues[payloadField] = try SyncPayload.encode(root) as NSData
        return target
    }

    static func decodeRoot(_ record: CKRecord) throws -> SyncRoot {
        try validateRecord(record, type: rootRecordType, identifier: rootRecordID, requiresPayload: true)
        let data = try payload(from: record)
        let object = try jsonObject(data)
        try requireFields(
            object,
            allowed: [
                "schemaVersion", "libraryGeneration", "identityKey", "disabled", "minimumProtocolVersion",
            ])
        let root = try SyncPayload.decode(SyncRoot.self, from: data)
        try root.validate()
        return root
    }

    /// Only CloudKit metadata/change tags are archived. Never archive a CKRecord with its values.
    static func archiveSystemFields(_ record: CKRecord) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        guard archiver.encodedData.count <= SyncPayload.maximumBytes else {
            throw SyncProtocolError.invalidSystemFields
        }
        return archiver.encodedData
    }

    static func restoreSystemFields(_ data: Data) throws -> CKRecord {
        guard !data.isEmpty, data.count <= SyncPayload.maximumBytes else {
            throw SyncProtocolError.invalidSystemFields
        }
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            unarchiver.decodingFailurePolicy = .setErrorAndReturn
            defer { unarchiver.finishDecoding() }
            guard let record = CKRecord(coder: unarchiver), unarchiver.error == nil,
                record.allKeys().isEmpty, record.encryptedValues.allKeys().isEmpty
            else {
                throw SyncProtocolError.invalidSystemFields
            }
            return record
        } catch {
            throw SyncProtocolError.invalidSystemFields
        }
    }

    private static func validateRecord(
        _ record: CKRecord, type: String, identifier: CKRecord.ID, requiresPayload: Bool
    ) throws {
        guard record.recordType == type, record.recordID == identifier else {
            throw SyncProtocolError.unexpectedRecord
        }
        // CKRecord.allKeys() includes encrypted keys even though ordinary subscripting returns nil
        // for those fields. Check values in the ordinary namespace, not the combined key list.
        guard record.allKeys().allSatisfy({ record[$0] == nil }) else {
            throw SyncProtocolError.plaintextField
        }
        let keys = Set(record.encryptedValues.allKeys())
        guard keys.isSubset(of: [payloadField]) else { throw SyncProtocolError.unexpectedField }
        if requiresPayload, keys != [payloadField] { throw SyncProtocolError.invalidPayload }
    }

    private static func payload(from record: CKRecord) throws -> Data {
        guard let data = record.encryptedValues[payloadField] as? Data else {
            throw SyncProtocolError.invalidPayload
        }
        try SyncPayload.validateJSON(data)
        return data
    }

    /// Version 1 refuses unknown protocol metadata before a read/modify/write can discard it.
    /// Entity payloads remain opaque bytes, so compatible domain data is preserved by the register.
    private static func validateEnvelopeShape(_ data: Data) throws {
        let object = try jsonObject(data)
        try requireFields(object, allowed: ["schemaVersion", "kind", "entityID", "generation", "register"])
        guard let register = object["register"] as? [String: Any],
            let context = register["context"] as? [String: Any],
            let versions = register["versions"] as? [[String: Any]]
        else {
            throw SyncProtocolError.invalidPayload
        }
        try requireFields(register, allowed: ["context", "versions"])
        try requireFields(context, allowed: ["counters"])
        for version in versions {
            try requireFields(version, allowed: ["dot", "payload", "modifiedAt"], optional: ["payload"])
            guard let dot = version["dot"] as? [String: Any] else { throw SyncProtocolError.invalidPayload }
            try requireFields(dot, allowed: ["installationID", "counter"])
        }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        try SyncPayload.validateJSON(data)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncProtocolError.invalidPayload
        }
        return result
    }

    private static func requireFields(
        _ object: [String: Any], allowed: Set<String>, optional: Set<String> = []
    ) throws {
        let keys = Set(object.keys)
        guard keys.isSubset(of: allowed) else { throw SyncProtocolError.unexpectedField }
        guard allowed.subtracting(optional).isSubset(of: keys) else { throw SyncProtocolError.invalidPayload }
    }
}
