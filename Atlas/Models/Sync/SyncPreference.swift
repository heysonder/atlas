import Foundation
import SwiftData

/// Portable scalar settings. Unedited defaults are not uploaded over existing cloud choices.
@Model
final class SyncPreference {
    @Attribute(.unique) var key: String
    var value: String
    var isExplicit: Bool
    var modifiedAt: Date

    init(key: String, value: String, isExplicit: Bool = false, modifiedAt: Date = .now) {
        self.key = key
        self.value = value
        self.isExplicit = isExplicit
        self.modifiedAt = modifiedAt
    }
}
