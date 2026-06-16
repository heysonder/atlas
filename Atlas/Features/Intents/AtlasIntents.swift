import AppIntents
import SwiftUI

// MARK: - Navigation intents (open the app to a place)

/// Opens Atlas to an in-app search.
struct ShowSearchResultsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search"
    static let description = IntentDescription("Search Atlas.")
    static let openAppWhenRun = true

    @Parameter(title: "Search", requestValueDialog: "What do you want to search for?")
    var query: String

    @Dependency var app: AppModel

    func perform() async throws -> some IntentResult {
        await MainActor.run { app.pendingIntent = .search(query) }
        return .result()
    }
}

/// "Show my For You" — opens the Home feed.
struct OpenForYouIntent: AppIntent {
    static let title: LocalizedStringResource = "Open For You"
    static let description = IntentDescription("Open your personalized Home feed.")
    static let openAppWhenRun = true

    @Dependency var app: AppModel

    func perform() async throws -> some IntentResult {
        await MainActor.run { app.pendingIntent = .forYou }
        return .result()
    }
}

/// Fixed set of Library destinations worth exposing outside the app. These are
/// screens with concrete saved content, not every tab or settings pane.
enum LibraryDestination: String, AppEnum {
    case downloads
    case history
    case playlists

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Library Section")

    static let caseDisplayRepresentations: [LibraryDestination: DisplayRepresentation] = [
        .downloads: DisplayRepresentation(title: "Downloads",
                                          subtitle: "Offline videos"),
        .history: DisplayRepresentation(title: "History",
                                        subtitle: "Recently watched videos"),
        .playlists: DisplayRepresentation(title: "Playlists",
                                          subtitle: "Saved video lists"),
    ]

    var libraryTarget: LibraryTarget {
        switch self {
        case .downloads: .downloads
        case .history: .history
        case .playlists: .playlists
        }
    }
}

/// "Open Downloads / History / Playlists" — deep-links into a specific Library
/// screen without exposing every internal navigation route.
struct OpenLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Library"
    static let description = IntentDescription("Open a section of your Atlas library.")
    static let openAppWhenRun = true

    @Parameter(title: "Section", default: .downloads,
               requestValueDialog: "Which Library section?")
    var destination: LibraryDestination

    @Dependency var app: AppModel

    func perform() async throws -> some IntentResult {
        let target = destination.libraryTarget
        await MainActor.run { app.pendingIntent = .openLibrary(target) }
        return .result()
    }
}

/// "Find videos about …" — returns matching videos as a value, so a Shortcut can
/// chain them: Find Videos → Get First Item → Add to Playlist / Play. (The search
/// schema above only *shows* results in-app; this one hands them back.)
struct FindVideosIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Videos"
    static let description = IntentDescription(
        "Search Atlas and return matching videos to use in a Shortcut.")

    @Parameter(title: "Search", requestValueDialog: "What do you want to find?")
    var query: String

    func perform() async throws -> some IntentResult & ReturnsValue<[VideoEntity]> {
        let results = await IntentDataStore.searchVideos(query, limit: 10)
        return .result(value: results)
    }
}

// MARK: - Resume watching (with a spoken reply + a snippet card)

/// "Resume watching" — picks up the most recent video. Replies with a Siri
/// snippet card and spoken dialog, then opens the player.
struct ResumeWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Watching"
    static let description = IntentDescription("Continue the last video you watched.")
    static let openAppWhenRun = true

    @Dependency var app: AppModel

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let watch: (title: String, uploader: String?)? = await MainActor.run {
            guard let entry = IntentDataStore.mostRecentWatch() else { return nil }
            app.pendingIntent = .resumeWatching
            return (entry.title, entry.uploader)
        }
        guard let watch else {
            return .result(
                dialog: "You don't have anything to resume yet.",
                view: ResumeSnippetView(title: nil, uploader: nil))
        }
        return .result(
            dialog: "Resuming \(watch.title).",
            view: ResumeSnippetView(title: watch.title, uploader: watch.uploader))
    }
}

// MARK: - Video actions

/// Plays a selected video entity, preferring the offline file when that video is
/// already downloaded.
struct PlayVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Video"
    static let description = IntentDescription("Play a video in Atlas.")
    static let openAppWhenRun = true

    @Parameter(title: "Video") var target: VideoEntity

    @Dependency var app: AppModel

    func perform() async throws -> some IntentResult {
        let request = PlayRequest(
            videoID: target.id, title: target.title, uploader: target.uploader,
            thumbnail: target.thumbnail,
            localURL: target.localFileName.map(DownloadStore.fileURL))
        await MainActor.run { app.nowPlaying = request }
        return .result()
    }
}

/// Saves a selected video for offline playback.
struct DownloadVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Download Video"
    static let description = IntentDescription("Save a video for offline viewing.")

    @Parameter(title: "Video") var target: VideoEntity

    @Dependency var app: AppModel
    @Dependency var downloads: DownloadManager

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = self.target
        await MainActor.run {
            downloads.download(videoID: target.id, title: target.title,
                               uploader: target.uploader, thumbnail: target.thumbnail, using: app)
        }
        return .result(dialog: "Downloading \(target.title).")
    }
}

/// Saves a selected video to one of your playlists. Both the video and the
/// playlist resolve as entities, so the playlist name can be spoken in the
/// phrase and the video can be chosen by search.
struct AddToPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Playlist"
    static let description = IntentDescription("Save a video to one of your playlists.")

    @Parameter(title: "Video", requestValueDialog: "Which video do you want to add?")
    var video: VideoEntity
    @Parameter(title: "Playlist", requestValueDialog: "Which playlist?")
    var playlist: PlaylistEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let video = self.video
        let playlist = self.playlist
        let wasNew = playlist.isNew
        let result = await MainActor.run {
            IntentDataStore.addVideo(video, to: playlist)
        }
        switch result {
        case .added where wasNew:
            return .result(dialog: "Created \(playlist.name) and added \(video.title).")
        case .added:
            return .result(dialog: "Added \(video.title) to \(playlist.name).")
        case .duplicate:
            return .result(dialog: "\(video.title) is already in \(playlist.name).")
        case .missing:
            return .result(dialog: "I couldn't save that right now.")
        }
    }
}

// MARK: - Snippet UI

/// Compact card Siri shows for "Resume watching".
struct ResumeSnippetView: View {
    let title: String?
    let uploader: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: title == nil ? "play.slash" : "play.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? "Nothing to resume")
                    .font(.headline)
                    .lineLimit(2)
                if let uploader {
                    Text(uploader)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}
