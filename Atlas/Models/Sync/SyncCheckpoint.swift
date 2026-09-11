import Foundation
import SwiftData

/// CKSyncEngine serialization is committed only after preceding incoming records are saved.
@Model
final class SyncCheckpoint {
    @Attribute(.unique) var namespace: String
    var data: Data
    var updatedAt: Date

    init(namespace: String, data: Data) {
        self.namespace = namespace
        self.data = data
        self.updatedAt = .now
    }
}
