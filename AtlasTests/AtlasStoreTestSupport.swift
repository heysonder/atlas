import Foundation
import SwiftData

@testable import Atlas

@MainActor
func makeTestContainer() throws -> ModelContainer {
    let schema = AtlasModelSchema.schema
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

func makeTestDefaults() -> UserDefaults {
    let suiteName = "atlas.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

final class MemoryInstanceSecureStore: InstanceSecureStoring {
    var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func loadInstanceURL() -> String? {
        value
    }

    func saveInstanceURL(_ value: String) {
        self.value = value
    }

    func clearInstanceURL() {
        value = nil
    }
}
