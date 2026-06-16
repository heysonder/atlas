import Foundation
import SwiftData
import PipedKit

struct PlaylistVideoSnapshot: Equatable {
    let videoID: String
    let title: String
    let uploader: String?
    let thumbnailURL: String?
    let duration: Int

    init(videoID: String, title: String, uploader: String? = nil,
         thumbnailURL: String? = nil, duration: Int = 0) {
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
        self.thumbnailURL = thumbnailURL
        self.duration = duration
    }

    init?(item: StreamItem) {
        guard let videoID = item.videoID else { return nil }
        self.init(videoID: videoID,
                  title: item.displayTitle,
                  uploader: item.uploaderName,
                  thumbnailURL: item.thumbnail,
                  duration: item.duration ?? 0)
    }

    init(request: PlayRequest, title: String? = nil, uploader: String? = nil,
         thumbnailURL: String? = nil, duration: Int = 0) {
        self.init(videoID: request.videoID,
                  title: title ?? request.title,
                  uploader: uploader ?? request.uploader,
                  thumbnailURL: thumbnailURL ?? request.thumbnail,
                  duration: duration)
    }

    init(video: VideoEntity) {
        self.init(videoID: video.id,
                  title: video.title,
                  uploader: video.uploader,
                  thumbnailURL: video.thumbnail)
    }
}

@MainActor
enum PlaylistStore {
    enum AddResult: Equatable {
        case added
        case duplicate
        case missing
    }

    static func contains(_ snapshot: PlaylistVideoSnapshot, in playlist: Playlist) -> Bool {
        containsVideoID(snapshot.videoID, in: playlist)
    }

    static func containsVideoID(_ videoID: String, in playlist: Playlist) -> Bool {
        playlist.videos.contains { $0.videoID == videoID }
    }

    @discardableResult
    static func add(_ snapshot: PlaylistVideoSnapshot, to playlist: Playlist,
                    in context: ModelContext, save: Bool = false) -> AddResult {
        guard !contains(snapshot, in: playlist) else { return .duplicate }
        let video = PlaylistVideo(
            videoID: snapshot.videoID,
            title: snapshot.title,
            uploader: snapshot.uploader,
            thumbnailURL: snapshot.thumbnailURL,
            duration: snapshot.duration)
        video.playlist = playlist
        context.insert(video)
        if save { try? context.save() }
        return .added
    }

    @discardableResult
    static func createPlaylist(named rawName: String, in context: ModelContext) -> Playlist? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let playlist = Playlist(name: name)
        context.insert(playlist)
        return playlist
    }

    static func playlist(id: UUID, in context: ModelContext) -> Playlist? {
        (try? context.fetch(FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.id == id })))?.first
    }

    static func playlist(named name: String, in context: ModelContext) -> Playlist? {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        return playlists.first {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }
}
