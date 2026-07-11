import Testing

@testable import Atlas

@MainActor
@Test func atlasModelSchemaContainsIntentModels() throws {
    let modelNames = Set(AtlasModelSchema.modelTypes.map { String(describing: $0) })

    #expect(modelNames.contains("SubscribedChannel"))
    #expect(modelNames.contains("HistoryEntry"))
    #expect(modelNames.contains("Playlist"))
    #expect(modelNames.contains("PlaylistVideo"))
    #expect(modelNames.contains("DownloadedVideo"))
    #expect(modelNames.contains("Feedback"))
    #expect(modelNames.contains("SearchEntry"))
    #expect(modelNames.contains("VideoSignalCacheEntry"))
    #expect(modelNames.contains("RecommendationProfileSnapshot"))

    _ = try makeTestContainer()
}
