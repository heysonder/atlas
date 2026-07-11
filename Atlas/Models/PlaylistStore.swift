import Foundation
import PipedKit
import SwiftData

struct PlaylistVideoSnapshot: Equatable {
    let videoID: String
    let title: String
    let uploader: String?
    let thumbnailURL: String?
    let duration: Int

    init(
        videoID: String, title: String, uploader: String? = nil,
        thumbnailURL: String? = nil, duration: Int = 0
    ) {
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
        self.thumbnailURL = thumbnailURL
        self.duration = duration
    }

    init?(item: StreamItem) {
        guard let videoID = item.videoID else { return nil }
        self.init(
            videoID: videoID,
            title: item.displayTitle,
            uploader: item.uploaderName,
            thumbnailURL: item.thumbnail,
            duration: item.duration ?? 0)
    }

    init(
        request: PlayRequest, title: String? = nil, uploader: String? = nil,
        thumbnailURL: String? = nil, duration: Int = 0
    ) {
        self.init(
            videoID: request.videoID,
            title: title ?? request.title,
            uploader: uploader ?? request.uploader,
            thumbnailURL: thumbnailURL ?? request.thumbnail,
            duration: duration)
    }

    init(video: VideoEntity) {
        self.init(
            videoID: video.id,
            title: video.title,
            uploader: video.uploader,
            thumbnailURL: video.thumbnail)
    }
}

@MainActor
enum PlaylistStore {
    static let favoritesPlaylistName = "Favorites"

    enum AddResult: Equatable {
        case added
        case duplicate
        case missing
    }

    enum RemoveResult: Equatable {
        case removed
        case missing
    }

    private enum MutationFailure: Error {
        case rejected
    }

    static func contains(_ snapshot: PlaylistVideoSnapshot, in playlist: Playlist) -> Bool {
        containsVideoID(snapshot.videoID, in: playlist)
    }

    static func containsVideoID(_ videoID: String, in playlist: Playlist) -> Bool {
        playlist.videos.contains { $0.videoID == videoID }
    }

    @discardableResult
    static func add(
        _ snapshot: PlaylistVideoSnapshot, to playlist: Playlist,
        in context: ModelContext, save: Bool = false
    ) -> AddResult {
        guard isValid(snapshot), isValid(playlist),
            playlist.videos.count < PersistedMetadataPolicy.maximumVideosPerPlaylist,
            let totalCount = try? context.fetchCount(FetchDescriptor<PlaylistVideo>()),
            totalCount < PersistedMetadataPolicy.maximumPlaylistVideos,
            PersistedMetadataCapacity.allowsAddingPlaylistVideo(in: context)
        else {
            return .missing
        }
        guard !contains(snapshot, in: playlist) else { return .duplicate }
        if save {
            guard
                performSavedMutation(
                    in: context,
                    {
                        insert(snapshot, into: playlist, in: context)
                    })
            else {
                return .missing
            }
        } else {
            insert(snapshot, into: playlist, in: context)
        }
        return .added
    }

    @discardableResult
    static func removeVideoID(
        _ videoID: String, from playlist: Playlist,
        in context: ModelContext, save: Bool = false
    ) -> RemoveResult {
        let videos = playlist.videos.filter { $0.videoID == videoID }
        guard !videos.isEmpty else {
            return .missing
        }
        if save {
            guard
                performSavedMutation(
                    in: context,
                    {
                        delete(videos, from: playlist, in: context)
                    })
            else {
                return .missing
            }
        } else {
            delete(videos, from: playlist, in: context)
        }
        return .removed
    }

    @discardableResult
    static func createPlaylist(named rawName: String, in context: ModelContext) -> Playlist? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try PersistedMetadataPolicy.requireNonemptyText(name, field: "playlist.name")
        } catch {
            return nil
        }
        guard let playlists = try? context.fetch(FetchDescriptor<Playlist>()),
            playlists.count < PersistedMetadataPolicy.maximumPlaylists,
            PersistedMetadataCapacity.allowsAddingTopLevelRecord(in: context)
        else { return nil }
        let key = PersistedMetadataPolicy.playlistNameKey(name)
        guard
            !playlists.contains(where: {
                PersistedMetadataPolicy.playlistNameKey($0.name) == key
            })
        else { return nil }
        let playlist = Playlist(name: name)
        context.insert(playlist)
        return playlist
    }

    /// Creates a genuinely new playlist and adds the video as one mutation.
    /// Unlike `add(_:toPlaylistNamed:)`, an existing same-named playlist is a
    /// rejection rather than a destination for the add.
    @discardableResult
    static func createPlaylist(
        named rawName: String,
        adding snapshot: PlaylistVideoSnapshot,
        in context: ModelContext,
        save: Bool = false
    ) -> AddResult {
        guard isValid(snapshot) else { return .missing }

        if save {
            var result: AddResult = .missing
            let mutation = {
                guard let playlist = createPlaylist(named: rawName, in: context) else {
                    throw MutationFailure.rejected
                }
                result = add(snapshot, to: playlist, in: context)
                guard result == .added else { throw MutationFailure.rejected }
            }
            return performSavedMutation(in: context, mutation) ? result : .missing
        }

        guard let playlist = createPlaylist(named: rawName, in: context) else {
            return .missing
        }
        let result = add(snapshot, to: playlist, in: context)
        if result != .added { context.delete(playlist) }
        return result
    }

    /// Adds to a same-named playlist or creates it and adds the video as one
    /// transaction. A rejected video never leaves an empty playlist behind.
    @discardableResult
    static func add(
        _ snapshot: PlaylistVideoSnapshot,
        toPlaylistNamed rawName: String,
        in context: ModelContext,
        save: Bool = false
    ) -> AddResult {
        if let existing = playlist(named: rawName, in: context) {
            return add(snapshot, to: existing, in: context, save: save)
        }
        guard isValid(snapshot) else { return .missing }

        if save {
            var result: AddResult = .missing
            let mutation = {
                guard let playlist = createPlaylist(named: rawName, in: context) else {
                    throw MutationFailure.rejected
                }
                result = add(snapshot, to: playlist, in: context)
                guard result == .added else { throw MutationFailure.rejected }
            }
            return performSavedMutation(in: context, mutation) ? result : .missing
        }

        guard let playlist = createPlaylist(named: rawName, in: context) else {
            return .missing
        }
        let result = add(snapshot, to: playlist, in: context)
        if result != .added { context.delete(playlist) }
        return result
    }

    static func delete(_ playlist: Playlist, in context: ModelContext) {
        context.delete(playlist)
    }

    static func playlist(id: UUID, in context: ModelContext) -> Playlist? {
        (try? context.fetch(
            FetchDescriptor<Playlist>(
                predicate: #Predicate { $0.id == id })))?.first
    }

    static func playlist(named name: String, in context: ModelContext) -> Playlist? {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        let key = PersistedMetadataPolicy.playlistNameKey(name)
        return playlists.first { PersistedMetadataPolicy.playlistNameKey($0.name) == key }
    }

    static func favoritesPlaylist(in context: ModelContext, createIfNeeded: Bool = false) -> Playlist? {
        if let playlist = playlist(named: favoritesPlaylistName, in: context) {
            return playlist
        }
        guard createIfNeeded else { return nil }
        return createPlaylist(named: favoritesPlaylistName, in: context)
    }

    static func isFavorite(videoID: String, in context: ModelContext) -> Bool {
        guard let playlist = favoritesPlaylist(in: context) else { return false }
        return containsVideoID(videoID, in: playlist)
    }

    @discardableResult
    static func addToFavorites(
        _ snapshot: PlaylistVideoSnapshot,
        in context: ModelContext,
        save: Bool = false
    ) -> AddResult {
        add(
            snapshot,
            toPlaylistNamed: favoritesPlaylistName,
            in: context,
            save: save)
    }

    @discardableResult
    static func removeFromFavorites(
        videoID: String,
        in context: ModelContext,
        save: Bool = false
    ) -> RemoveResult {
        guard let playlist = favoritesPlaylist(in: context) else { return .missing }
        return removeVideoID(videoID, from: playlist, in: context, save: save)
    }

    private static func isValid(_ snapshot: PlaylistVideoSnapshot) -> Bool {
        do {
            try PersistedMetadataPolicy.requireIdentifier(
                snapshot.videoID, field: "playlist.videoID")
            try PersistedMetadataPolicy.requireText(snapshot.title, field: "playlist.title")
            try PersistedMetadataPolicy.requireOptionalText(
                snapshot.uploader, field: "playlist.uploader")
            try PersistedMetadataPolicy.requireOptionalURL(
                snapshot.thumbnailURL, field: "playlist.thumbnailURL")
            try PersistedMetadataPolicy.requirePlaybackDuration(
                snapshot.duration, field: "playlist.duration")
            return true
        } catch {
            return false
        }
    }

    private static func isValid(_ playlist: Playlist) -> Bool {
        do {
            try PersistedMetadataPolicy.requireNonemptyText(
                playlist.name, field: "playlist.name")
            try PersistedMetadataPolicy.requireFiniteDate(
                playlist.createdAt, field: "playlist.createdAt")
            return true
        } catch {
            return false
        }
    }

    private static func insert(
        _ snapshot: PlaylistVideoSnapshot,
        into playlist: Playlist,
        in context: ModelContext
    ) {
        let video = PlaylistVideo(
            videoID: snapshot.videoID,
            title: snapshot.title,
            uploader: snapshot.uploader,
            thumbnailURL: snapshot.thumbnailURL,
            duration: snapshot.duration)
        video.playlist = playlist
        context.insert(video)
    }

    private static func delete(
        _ videos: [PlaylistVideo],
        from playlist: Playlist,
        in context: ModelContext
    ) {
        playlist.videos.removeAll { video in
            videos.contains { $0.persistentModelID == video.persistentModelID }
        }
        for video in videos {
            context.delete(video)
        }
    }

    /// Run a mutation and its save as one SwiftData transaction. A failed save
    /// rolls back the mutation instead of leaving optimistic in-memory state.
    static func performSavedMutation(
        in context: ModelContext,
        _ mutation: () throws -> Void
    ) -> Bool {
        do {
            try context.transaction {
                try mutation()
            }
            return true
        } catch {
            context.rollback()
            return false
        }
    }
}
