import SwiftData

enum AtlasModelSchema {
    nonisolated static let modelTypes: [any PersistentModel.Type] = [
        SubscribedChannel.self,
        HistoryEntry.self,
        Playlist.self,
        PlaylistVideo.self,
        DownloadedVideo.self,
        Feedback.self,
        SearchEntry.self,
        VideoSignalCacheEntry.self,
        RecommendationProfileSnapshot.self,
        FeedImpressionEntry.self,
        RecommendationOutcomeEntry.self,
        SyncRecordState.self,
        SyncCheckpoint.self,
        SyncEnrollment.self,
        SyncPreference.self,
        FeedImpressionBaseline.self,
        RecommendationActivityState.self,
    ]

    static var schema: Schema {
        Schema(versionedSchema: AtlasSchemaV2.self)
    }
}
