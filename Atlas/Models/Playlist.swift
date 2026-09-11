import Foundation
import SwiftData

/// A playlist with a stable identity shared by local persistence and optional sync.
@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    /// Stable system identity; ordinary playlists remain identified by their UUID.
    var systemKind: String?
    /// New on explicit Favorites recreation, so old offline children stay deleted.
    var syncIncarnation: String?
    /// IDs used by older local shortcuts before Favorites was canonicalized.
    var legacyIDs: [UUID]?
    @Relationship(deleteRule: .cascade, inverse: \PlaylistVideo.playlist)
    var videos: [PlaylistVideo]

    init(
        id: UUID = UUID(), name: String, createdAt: Date = .now,
        videos: [PlaylistVideo] = [], systemKind: String? = nil, legacyIDs: [UUID]? = nil,
        syncIncarnation: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.videos = videos
        self.systemKind = systemKind
        self.syncIncarnation = syncIncarnation
        self.legacyIDs = legacyIDs
    }

    /// Videos in the order they were added.
    var orderedVideos: [PlaylistVideo] {
        videos.sorted {
            if $0.addedAt != $1.addedAt { return $0.addedAt < $1.addedAt }
            return $0.videoID < $1.videoID
        }
    }
}

/// A video saved inside a playlist (denormalized so it shows without a refetch).
@Model
final class PlaylistVideo {
    var videoID: String
    var title: String
    var uploader: String?
    var thumbnailURL: String?
    var duration: Int
    var addedAt: Date
    var playlist: Playlist?

    init(
        videoID: String, title: String, uploader: String? = nil,
        thumbnailURL: String? = nil, duration: Int = 0, addedAt: Date = .now
    ) {
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.addedAt = addedAt
    }
}
