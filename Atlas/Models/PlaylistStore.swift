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
        // Piped reports -1 for live streams; store "unknown" instead of refusing the save.
        self.duration = PersistedMetadataPolicy.sanitizedPlaybackDuration(duration)
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
    static let favoritesSystemKind = "favorites"
    static let favoritesPlaylistID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

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

    /// `save` is retained for source compatibility. Every successful user
    /// mutation now durably saves its library changes and sync journal together.
    @discardableResult
    static func add(
        _ snapshot: PlaylistVideoSnapshot, to playlist: Playlist,
        in context: ModelContext, save: Bool = false
    ) -> AddResult {
        guard isValid(snapshot), isValid(playlist) else { return .missing }
        guard !contains(snapshot, in: playlist) else { return .duplicate }
        guard canAddVideo(to: playlist, in: context) else { return .missing }
        return performSavedMutation(in: context, captureChanges: false) {
            insert(snapshot, into: playlist, in: context)
            try capture(playlist, videoID: snapshot.videoID, in: context)
        } ? .added : .missing
    }

    @discardableResult
    static func removeVideoID(
        _ videoID: String, from playlist: Playlist,
        in context: ModelContext, save: Bool = false
    ) -> RemoveResult {
        let videos = playlist.videos.filter { $0.videoID == videoID }
        guard !videos.isEmpty else { return .missing }
        return performSavedMutation(in: context, captureChanges: false) {
            try LibraryDeletionJournal.record(
                kind: .playlistVideo,
                entityID: LibrarySyncJournal.playlistVideoIdentity(
                    playlistID: playlist.id, videoID: videoID, incarnation: playlist.syncIncarnation),
                sourceIdentifier: videoID, in: context)
            delete(videos, from: playlist, in: context)
        } ? .removed : .missing
    }

    @discardableResult
    static func createPlaylist(named rawName: String, in context: ModelContext) -> Playlist? {
        guard (try? validatedPlaylistName(rawName, in: context)) != nil else { return nil }
        var result: Playlist?
        let committed = performSavedMutation(in: context, captureChanges: false) {
            let playlist = try insertPlaylist(named: rawName, in: context)
            result = playlist
            try LibrarySyncJournal.capture(
                kind: .playlist, entityID: playlist.id.uuidString.lowercased(), in: context)
        }
        return committed ? result : nil
    }

    /// Local name-based creation remains unambiguous. Sync preserves independent
    /// UUIDs even when two devices created the same name while offline.
    @discardableResult
    static func createPlaylist(
        named rawName: String, adding snapshot: PlaylistVideoSnapshot,
        in context: ModelContext, save: Bool = false
    ) -> AddResult {
        guard isValid(snapshot),
            (try? validatedPlaylistName(rawName, addingVideo: true, in: context)) != nil
        else { return .missing }
        return performSavedMutation(in: context, captureChanges: false) {
            let playlist = try insertPlaylist(named: rawName, in: context)
            guard canAddVideo(to: playlist, in: context) else { throw MutationFailure.rejected }
            insert(snapshot, into: playlist, in: context)
            try capture(playlist, videoID: snapshot.videoID, in: context)
        } ? .added : .missing
    }

    /// Ambiguous names are rejected; callers can choose the intended UUID.
    @discardableResult
    static func add(
        _ snapshot: PlaylistVideoSnapshot, toPlaylistNamed rawName: String,
        in context: ModelContext, save: Bool = false
    ) -> AddResult {
        if PersistedMetadataPolicy.playlistNameKey(rawName)
            == PersistedMetadataPolicy.playlistNameKey(favoritesPlaylistName)
        {
            return addToFavorites(snapshot, in: context, save: save)
        }
        guard let matches = try? playlists(named: rawName, in: context), matches.count <= 1 else {
            return .missing
        }
        if let existing = matches.first { return add(snapshot, to: existing, in: context, save: save) }
        return createPlaylist(named: rawName, adding: snapshot, in: context, save: save)
    }

    @discardableResult
    static func delete(_ playlist: Playlist, in context: ModelContext) -> Bool {
        performSavedMutation(in: context, captureChanges: false) {
            try LibrarySyncJournal.record(
                kind: .playlist, entityID: playlist.id.uuidString.lowercased(), payload: nil, in: context)
            for video in playlist.videos {
                try LibraryDeletionJournal.record(
                    kind: .playlistVideo,
                    entityID: LibrarySyncJournal.playlistVideoIdentity(
                        playlistID: playlist.id, videoID: video.videoID, incarnation: playlist.syncIncarnation),
                    sourceIdentifier: video.videoID, in: context)
            }
            context.delete(playlist)
        }
    }

    static func playlist(id: UUID, in context: ModelContext) -> Playlist? {
        let descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        if let exact = try? context.fetch(descriptor).first { return exact }
        return (try? context.fetch(FetchDescriptor<Playlist>()))?.first { $0.legacyIDs?.contains(id) == true }
    }

    static func playlist(named name: String, in context: ModelContext) -> Playlist? {
        guard let matches = try? playlists(named: name, in: context), matches.count == 1 else { return nil }
        return matches[0]
    }

    /// A deterministic label for independently synced playlists with equal names.
    static func displayName(for playlist: Playlist, among playlists: [Playlist]) -> String {
        let key = PersistedMetadataPolicy.playlistNameKey(playlist.name)
        guard playlists.filter({ PersistedMetadataPolicy.playlistNameKey($0.name) == key }).count > 1 else {
            return playlist.name
        }
        return "\(playlist.name) · \(playlist.id.uuidString.prefix(8).lowercased())"
    }

    /// A read: it never mutates the store. An older installation whose legacy
    /// Favorites row has not been adopted yet (adoption runs at launch and before
    /// every Favorites mutation) is answered with that row as-is, so a view bound
    /// to it is never deleted underneath a read such as the player's favorite state.
    static func favoritesPlaylist(in context: ModelContext, createIfNeeded: Bool = false) -> Playlist? {
        if let existing = playlist(id: favoritesPlaylistID, in: context) { return existing }
        if let legacy = legacyFavorites(in: context).first { return legacy }
        guard createIfNeeded else { return nil }
        return createPlaylist(named: favoritesPlaylistName, in: context)
    }

    private static func legacyFavorites(in context: ModelContext) -> [Playlist] {
        ((try? context.fetch(FetchDescriptor<Playlist>())) ?? [])
            .filter { isLegacyFavorite($0) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Runs once at launch for every install (sync or not) and before Favorites
    /// mutations, so the canonical row exists before any view can bind to a
    /// legacy one. Adoption journals exactly the rows it touches; a whole-library
    /// capture here would scan every table on the main actor for one tap.
    @discardableResult
    static func adoptLegacyFavoritesIfNeeded(in context: ModelContext) -> Bool {
        guard !legacyFavorites(in: context).isEmpty else { return true }
        return performSavedMutation(in: context, captureChanges: false) { try adoptLegacyFavorites(in: context) }
    }

    /// Called once by sync migration, inside its transaction, at launch, and
    /// before Favorites mutations on older installations. Legacy IDs remain aliases.
    static func adoptLegacyFavorites(in context: ModelContext) throws {
        let playlists = try context.fetch(FetchDescriptor<Playlist>())
        let legacy = playlists.filter { isLegacyFavorite($0) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard !legacy.isEmpty else { return }
        let allVideoIDs = Set(
            playlists.filter {
                $0.id == favoritesPlaylistID || isLegacyFavorite($0)
            }.flatMap { $0.videos.map(\.videoID) })
        guard allVideoIDs.count <= PersistedMetadataPolicy.maximumVideosPerPlaylist else {
            throw MutationFailure.rejected
        }
        let canonical: Playlist
        if let existing = playlists.first(where: { $0.id == favoritesPlaylistID }) {
            canonical = existing
        } else {
            canonical = Playlist(
                id: favoritesPlaylistID, name: favoritesPlaylistName,
                createdAt: legacy.map(\.createdAt).min() ?? .now, systemKind: favoritesSystemKind)
            context.insert(canonical)
        }
        canonical.systemKind = favoritesSystemKind
        var aliases = Set(canonical.legacyIDs ?? [])
        var members = Dictionary(canonical.videos.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })
        for old in legacy {
            let oldIdentity = old.id.uuidString.lowercased()
            if try LibrarySyncJournal.hasRecord(kind: .playlist, entityID: oldIdentity, in: context) {
                try LibrarySyncJournal.record(
                    kind: .playlist, entityID: oldIdentity, payload: nil, in: context)
            }
            for video in old.videos {
                let identity = LibrarySyncJournal.playlistVideoIdentity(
                    playlistID: old.id, videoID: video.videoID, incarnation: old.syncIncarnation)
                if try LibrarySyncJournal.hasRecord(kind: .playlistVideo, entityID: identity, in: context) {
                    try LibrarySyncJournal.record(
                        kind: .playlistVideo, entityID: identity, payload: nil, in: context)
                }
            }
            aliases.insert(old.id)
            aliases.formUnion(old.legacyIDs ?? [])
            let videos = old.videos
            old.videos.removeAll()
            for video in videos {
                if let existing = members[video.videoID] {
                    existing.addedAt = min(existing.addedAt, video.addedAt)
                    context.delete(video)
                } else {
                    video.playlist = canonical
                    members[video.videoID] = video
                }
            }
            context.delete(old)
        }
        canonical.legacyIDs = aliases.filter { $0 != favoritesPlaylistID }.sorted { $0.uuidString < $1.uuidString }
        // Journal the canonical playlist and each merged membership explicitly, so
        // callers never need a whole-library capture to make adoption durable.
        try LibrarySyncJournal.capture(
            kind: .playlist, entityID: canonical.id.uuidString.lowercased(), in: context)
        for videoID in members.keys {
            try LibrarySyncJournal.capture(
                kind: .playlistVideo,
                entityID: LibrarySyncJournal.playlistVideoIdentity(
                    playlistID: canonical.id, videoID: videoID, incarnation: canonical.syncIncarnation),
                in: context)
        }
    }

    static func isFavorite(videoID: String, in context: ModelContext) -> Bool {
        guard let playlist = favoritesPlaylist(in: context) else { return false }
        return containsVideoID(videoID, in: playlist)
    }

    @discardableResult
    static func addToFavorites(
        _ snapshot: PlaylistVideoSnapshot, in context: ModelContext, save: Bool = false
    ) -> AddResult {
        guard isValid(snapshot), adoptLegacyFavoritesIfNeeded(in: context) else { return .missing }
        if let existing = favoritesPlaylist(in: context) {
            return add(snapshot, to: existing, in: context, save: save)
        }
        return createPlaylist(named: favoritesPlaylistName, adding: snapshot, in: context, save: save)
    }

    @discardableResult
    static func removeFromFavorites(
        videoID: String, in context: ModelContext, save: Bool = false
    ) -> RemoveResult {
        guard adoptLegacyFavoritesIfNeeded(in: context), let playlist = favoritesPlaylist(in: context) else {
            return .missing
        }
        return removeVideoID(videoID, from: playlist, in: context, save: save)
    }

    private static func isLegacyFavorite(_ playlist: Playlist) -> Bool {
        playlist.id != favoritesPlaylistID
            && (playlist.systemKind == favoritesSystemKind
                || (playlist.systemKind == nil
                    && PersistedMetadataPolicy.playlistNameKey(playlist.name)
                        == PersistedMetadataPolicy.playlistNameKey(favoritesPlaylistName)))
    }

    private static func playlists(named name: String, in context: ModelContext) throws -> [Playlist] {
        let key = PersistedMetadataPolicy.playlistNameKey(name)
        return try context.fetch(FetchDescriptor<Playlist>()).filter {
            PersistedMetadataPolicy.playlistNameKey($0.name) == key
        }
    }

    /// Reject ordinary validation/capacity failures before entering a mutation
    /// transaction, preserving unrelated changes already pending in the context.
    private static func validatedPlaylistName(
        _ rawName: String, addingVideo: Bool = false, in context: ModelContext
    ) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        try PersistedMetadataPolicy.requireNonemptyText(name, field: "playlist.name")
        let playlists = try context.fetch(FetchDescriptor<Playlist>())
        let key = PersistedMetadataPolicy.playlistNameKey(name)
        guard playlists.count < PersistedMetadataPolicy.maximumPlaylists,
            PersistedMetadataCapacity.allowsAddingTopLevelRecord(in: context),
            !playlists.contains(where: { PersistedMetadataPolicy.playlistNameKey($0.name) == key })
        else { throw MutationFailure.rejected }
        if addingVideo {
            let videoCount = try context.fetchCount(FetchDescriptor<PlaylistVideo>())
            guard videoCount < PersistedMetadataPolicy.maximumPlaylistVideos else { throw MutationFailure.rejected }
            _ = try PersistedMetadataPolicy.checkedSum(
                context.fetchCount(FetchDescriptor<HistoryEntry>()),
                context.fetchCount(FetchDescriptor<SearchEntry>()),
                context.fetchCount(FetchDescriptor<SubscribedChannel>()),
                playlists.count,
                context.fetchCount(FetchDescriptor<Feedback>()),
                videoCount, 2,
                maximum: PersistedMetadataPolicy.maximumTotalRecords, field: "records")
        }
        return name
    }

    private static func insertPlaylist(named rawName: String, in context: ModelContext) throws -> Playlist {
        let name = try validatedPlaylistName(rawName, in: context)
        let key = PersistedMetadataPolicy.playlistNameKey(name)
        let isFavorite = key == PersistedMetadataPolicy.playlistNameKey(favoritesPlaylistName)
        var incarnation: String?
        if isFavorite,
            let state = try SyncStoreAdapter(context: context).state(
                kind: .playlist, entityID: favoritesPlaylistID.uuidString.lowercased()),
            try SyncPayload.decode(SyncEnvelope.self, from: state.envelopeData).isTombstone
        {
            incarnation = UUID().uuidString.lowercased()
        }
        let playlist = Playlist(
            id: isFavorite ? favoritesPlaylistID : UUID(),
            name: isFavorite ? favoritesPlaylistName : name,
            systemKind: isFavorite ? favoritesSystemKind : nil, syncIncarnation: incarnation)
        context.insert(playlist)
        return playlist
    }

    private static func canAddVideo(to playlist: Playlist, in context: ModelContext) -> Bool {
        playlist.videos.count < PersistedMetadataPolicy.maximumVideosPerPlaylist
            && ((try? context.fetchCount(FetchDescriptor<PlaylistVideo>())) ?? Int.max)
                < PersistedMetadataPolicy.maximumPlaylistVideos
            && PersistedMetadataCapacity.allowsAddingPlaylistVideo(in: context)
    }

    private static func isValid(_ snapshot: PlaylistVideoSnapshot) -> Bool {
        do {
            try PersistedMetadataPolicy.requireIdentifier(snapshot.videoID, field: "playlist.videoID")
            try PersistedMetadataPolicy.requireText(snapshot.title, field: "playlist.title")
            try PersistedMetadataPolicy.requireOptionalText(snapshot.uploader, field: "playlist.uploader")
            try PersistedMetadataPolicy.requireOptionalURL(snapshot.thumbnailURL, field: "playlist.thumbnailURL")
            try PersistedMetadataPolicy.requirePlaybackDuration(snapshot.duration, field: "playlist.duration")
            return true
        } catch { return false }
    }

    private static func isValid(_ playlist: Playlist) -> Bool {
        do {
            try PersistedMetadataPolicy.requireNonemptyText(playlist.name, field: "playlist.name")
            try PersistedMetadataPolicy.requireFiniteDate(playlist.createdAt, field: "playlist.createdAt")
            return true
        } catch { return false }
    }

    private static func insert(
        _ snapshot: PlaylistVideoSnapshot, into playlist: Playlist, in context: ModelContext
    ) {
        let video = PlaylistVideo(
            videoID: snapshot.videoID, title: snapshot.title, uploader: snapshot.uploader,
            thumbnailURL: snapshot.thumbnailURL, duration: snapshot.duration)
        video.playlist = playlist
        context.insert(video)
    }

    private static func delete(_ videos: [PlaylistVideo], from playlist: Playlist, in context: ModelContext) {
        playlist.videos.removeAll { video in
            videos.contains { $0.persistentModelID == video.persistentModelID }
        }
        for video in videos { context.delete(video) }
    }

    private static func capture(
        _ playlist: Playlist, videoID: String, in context: ModelContext
    ) throws {
        try LibrarySyncJournal.capture(
            kind: .playlist, entityID: playlist.id.uuidString.lowercased(), in: context)
        try LibrarySyncJournal.capture(
            kind: .playlistVideo,
            entityID: LibrarySyncJournal.playlistVideoIdentity(
                playlistID: playlist.id, videoID: videoID, incarnation: playlist.syncIncarnation),
            in: context)
    }

    static func performSavedMutation(
        in context: ModelContext, captureChanges: Bool = true, _ mutation: () throws -> Void
    ) -> Bool {
        do {
            try LibrarySyncJournal.transaction(in: context, captureChanges: captureChanges, mutation)
            return true
        } catch { return false }
    }
}
