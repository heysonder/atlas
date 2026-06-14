import Foundation
import SwiftData

/// A deferred action requested by Siri or an App Shortcut. The intent sets one of
/// these on `AppModel`; `RootView` consumes it once the UI is alive and clears it.
/// Kept as a plain value type so it can be created off the main actor in an intent
/// and handed to the main-actor model.
enum AtlasIntentAction: Equatable, Sendable {
    case search(String)
    case resumeWatching
    case forYou
    case openDownloads
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
    static var container: ModelContainer?

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

    static func addVideo(_ video: VideoEntity, toPlaylistID id: UUID) -> AddResult {
        guard let context, let playlist = playlist(id: id) else { return .missing }
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
