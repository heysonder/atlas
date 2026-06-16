import SwiftData

enum AtlasModelSchema {
    static let modelTypes: [any PersistentModel.Type] = [
        SubscribedChannel.self,
        HistoryEntry.self,
        Playlist.self,
        PlaylistVideo.self,
        DownloadedVideo.self,
        Feedback.self,
        SearchEntry.self,
        VideoSignalCacheEntry.self,
        RecommendationProfileSnapshot.self,
    ]

    static var schema: Schema {
        Schema(modelTypes)
    }
}
