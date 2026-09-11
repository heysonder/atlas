import Foundation
import SwiftData

/// The durable per-entity journal. A newer revision survives an older upload acknowledgment.
@Model
final class SyncRecordState {
    @Attribute(.unique) var key: String
    var namespace: String
    var kindRawValue: String
    var entityID: String
    var envelopeData: Data
    var systemFields: Data?
    var localRevision: Int64
    var acknowledgedRevision: Int64
    var materializedPayload: Data?
    var isMaterialized: Bool
    var playlistIncarnation: String?
    var isObsolete: Bool = false
    var deletionMarker: String

    init(key: String, namespace: String, kind: String, entityID: String, envelopeData: Data) {
        self.key = key
        self.namespace = namespace
        self.kindRawValue = kind
        self.entityID = entityID
        self.envelopeData = envelopeData
        self.localRevision = 0
        self.acknowledgedRevision = 0
        self.isMaterialized = false
        self.deletionMarker = "initial"
    }
}
