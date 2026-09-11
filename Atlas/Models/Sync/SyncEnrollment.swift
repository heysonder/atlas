import Foundation
import SwiftData

/// This row alone never grants consent: the coordinator also requires its device-only marker.
@Model
final class SyncEnrollment {
    @Attribute(.unique) var id: String
    var replicaID: String = UUID().uuidString.lowercased()
    var installationID: String
    var optedIn: Bool
    var accountID: String?
    var libraryGeneration: String?
    var environment: String
    var consentInstallationID: String?
    var hasCompletedBootstrap: Bool
    var lastSyncAt: Date?
    var phase: String
    var counter: Int64
    var retiredGenerationsData: Data = Data("{}".utf8)
    var generationsData: Data

    init() {
        self.id = "default"
        self.installationID = UUID().uuidString.lowercased()
        self.optedIn = false
        self.environment = "development"
        self.hasCompletedBootstrap = false
        self.phase = "off"
        self.counter = 0
        self.generationsData = Data("{}".utf8)
    }
}
