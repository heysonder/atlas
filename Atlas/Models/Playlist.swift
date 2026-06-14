import Foundation
import SwiftData

/// A locally created playlist.
@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \PlaylistVideo.playlist)
    var videos: [PlaylistVideo]

    init(id: UUID = UUID(), name: String, createdAt: Date = .now, videos: [PlaylistVideo] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.videos = videos
    }

    /// Videos in the order they were added.
    var orderedVideos: [PlaylistVideo] {
        videos.sorted { $0.addedAt < $1.addedAt }
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

    init(videoID: String, title: String, uploader: String? = nil,
         thumbnailURL: String? = nil, duration: Int = 0, addedAt: Date = .now) {
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.addedAt = addedAt
    }
}
