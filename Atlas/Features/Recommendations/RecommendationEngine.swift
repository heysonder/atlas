import SwiftData

/// Shared candidate generation + the two ranking strategies.
@MainActor
struct RecommendationEngine {
    let app: AppModel
    let modelContext: ModelContext?

    init(app: AppModel, modelContext: ModelContext? = nil) {
        self.app = app
        self.modelContext = modelContext
    }
}
