import SwiftData

@MainActor
enum PersistedMetadataCapacity {
    static func allowsAddingTopLevelRecord(in context: ModelContext) -> Bool {
        allowsAdding(topLevel: 1, playlistVideos: 0, in: context)
    }

    static func allowsAddingPlaylistVideo(in context: ModelContext) -> Bool {
        allowsAdding(topLevel: 0, playlistVideos: 1, in: context)
    }

    private static func allowsAdding(
        topLevel: Int,
        playlistVideos: Int,
        in context: ModelContext
    ) -> Bool {
        do {
            _ = try PersistedMetadataPolicy.checkedSum(
                context.fetchCount(FetchDescriptor<HistoryEntry>()),
                context.fetchCount(FetchDescriptor<SearchEntry>()),
                context.fetchCount(FetchDescriptor<SubscribedChannel>()),
                context.fetchCount(FetchDescriptor<Playlist>()),
                context.fetchCount(FetchDescriptor<Feedback>()),
                context.fetchCount(FetchDescriptor<PlaylistVideo>()),
                topLevel,
                playlistVideos,
                maximum: PersistedMetadataPolicy.maximumTotalRecords,
                field: "records"
            )
            return true
        } catch {
            return false
        }
    }
}
