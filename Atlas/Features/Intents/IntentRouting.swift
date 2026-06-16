import Foundation
import SwiftData
import PipedKit

/// A deferred action requested by Siri or an App Shortcut. The intent sets one of
/// these on `AppModel`; `RootView` consumes it once the UI is alive and clears it.
/// Kept as a plain value type so it can be created off the main actor in an intent
/// and handed to the main-actor model.
enum AtlasIntentAction: Equatable, Sendable {
    case search(String)
    case resumeWatching
    case forYou
    case openLibrary(LibraryTarget)
}

/// A Library sub-screen to deep-link into. `ProfileView` owns its own navigation
/// stack, so it watches `AppModel.libraryTarget` and pushes the matching route.
enum LibraryTarget: Equatable, Sendable {
    case downloads
    case history
    case playlists
}

/// Main-actor access to the app's SwiftData store from App Intents / Spotlight,
/// which run outside the SwiftUI environment and so can't use `@Environment`.
/// Set once at launch in `AtlasApp.init`.
@MainActor
enum IntentDataStore {
    /// Set by the app at launch. When an intent runs *headless* (Siri/Shortcuts
    /// without opening the app), this is nil — so `container` and `client` below
    /// fall back to building their own against the same store / saved instance.
    static var injectedContainer: ModelContainer?
    static var app: AppModel?

    /// The app's container if it launched, else a private one over the same store
    /// so playlists/downloads/history are reachable from a background intent.
    static var container: ModelContainer? {
        if let injectedContainer { return injectedContainer }
        injectedContainer = try? ModelContainer(
            for: SubscribedChannel.self, HistoryEntry.self, Playlist.self,
            PlaylistVideo.self, DownloadedVideo.self, Feedback.self, SearchEntry.self,
            VideoSignalCacheEntry.self, RecommendationProfileSnapshot.self)
        return injectedContainer
    }

    /// A Piped client for network search that works without the app process:
    /// reads the selected instance straight from defaults (mirrors `AppModel`).
    /// Nil means the user has not opted into online Piped calls.
    static var client: PipedClient? {
        if let app { return try? app.client }
        let raw = UserDefaults.standard.string(forKey: AppModel.instanceKey)
        let normalized = raw.map(AppModel.normalize) ?? ""
        return PipedClient(instanceString: normalized)
    }

    private static var context: ModelContext? { container?.mainContext }

    /// Completed downloads, newest first. Pass `ids` to fetch a specific subset.
    static func downloads(ids: [String]? = nil, limit: Int? = nil) -> [DownloadedVideo] {
        guard let context else { return [] }
        var descriptor = FetchDescriptor<DownloadedVideo>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let ids {
            let set = Set(ids)
            descriptor.predicate = #Predicate { set.contains($0.videoID) }
        }
        if let limit { descriptor.fetchLimit = limit }
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The watch-history rows we surface to Spotlight — most recent first.
    static func recentHistory(limit: Int = 150) -> [HistoryEntry] {
        guard let context else { return [] }
        var descriptor = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.watchedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The single most recent watch — what "Resume watching" plays.
    static func mostRecentWatch() -> HistoryEntry? {
        recentHistory(limit: 1).first
    }

    // MARK: Network search (for Siri entity resolution + the Find Videos intent)

    /// Runs a YouTube search through the selected instance and returns matching
    /// videos as entities. Results are also recorded in the on-screen registry so
    /// a later `entities(for:)` can resolve them by id (e.g. when chained into
    /// "add to playlist").
    static func searchVideos(_ query: String, limit: Int = 10) async -> [VideoEntity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let client else { return [] }
        let videos = ((try? await client.search(trimmed, filter: "videos")) ?? [])
            .filter(\.isVideo)
            .prefix(limit)
        let items = Array(videos)
        VisibleVideoRegistry.shared.record(items)
        return items.map(VideoEntity.init)
    }

    // MARK: Playlists

    /// All playlists, oldest first (matches the Library ordering).
    static func playlists() -> [Playlist] {
        guard let context else { return [] }
        let descriptor = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func playlist(id: UUID) -> Playlist? {
        guard let context else { return nil }
        return (try? context.fetch(FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.id == id })))?.first
    }

    /// Adds a video to a playlist, de-duped by video id (mirrors the context
    /// menu's add). Returns `.added`, `.duplicate`, or `.missing` so the intent
    /// can speak the right reply.
    enum AddResult { case added, duplicate, missing }

    /// Adds to an existing playlist, or creates one first when the entity is a
    /// "to-create" placeholder (so "add this to Watch Later" works even if no
    /// such playlist exists yet).
    static func addVideo(_ video: VideoEntity, to entity: PlaylistEntity) -> AddResult {
        guard let context else { return .missing }
        let playlist: Playlist
        if entity.isNew {
            // Reuse a same-named playlist if one was made in the meantime.
            if let existing = playlists().first(where: {
                $0.name.localizedCaseInsensitiveCompare(entity.name) == .orderedSame
            }) {
                playlist = existing
            } else {
                playlist = Playlist(name: entity.name)
                context.insert(playlist)
            }
        } else if let id = UUID(uuidString: entity.id), let existing = self.playlist(id: id) {
            playlist = existing
        } else {
            return .missing
        }

        guard !playlist.videos.contains(where: { $0.videoID == video.id }) else { return .duplicate }
        let entry = PlaylistVideo(videoID: video.id, title: video.title,
                                  uploader: video.uploader, thumbnailURL: video.thumbnail)
        entry.playlist = playlist
        context.insert(entry)
        // Save explicitly: the intent may run while the app is backgrounded, where
        // autosave wouldn't have flushed before the process suspends.
        try? context.save()
        return .added
    }
}
