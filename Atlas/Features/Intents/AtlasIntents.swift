import AppIntents
import SwiftUI

// MARK: - Navigation intents (open the app to a place)

/// "Search for lo-fi beats in Atlas" — real in-app search via the App Intent
/// domain schema. `@AppIntent(schema: .system.search)` both conforms this to
/// `ShowInAppSearchResultsIntent` AND registers it in the assistant domain the
/// Gemini-rebuilt Siri uses to route "search in <app>" from natural language —
/// which a plain protocol conformance doesn't do.
@AppIntent(schema: .system.search)
struct ShowSearchResultsIntent {
    /// A video app searches general content (vs. a movies/TV-scoped store).
    static let searchScopes: [StringSearchScope] = [.general]

    @Parameter(title: "Search")
    var criteria: StringSearchCriteria

    @Dependency var app: AppModel

    func perform() async throws -> some IntentResult {
        let term = criteria.term
        await MainActor.run { app.pendingIntent = .search(term) }
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

/// "Open my downloads" — deep-links into the Library → Downloads screen.
struct OpenDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Downloads"
    static let description = IntentDescription("See your offline downloads.")
    static let openAppWhenRun = true

    @Dependency var app: AppModel

    func perform() async throws -> some IntentResult {
        await MainActor.run { app.pendingIntent = .openDownloads }
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

// MARK: - Contextual actions (operate on a video — incl. on-screen "this")

/// "Play this" — plays a video entity (the one on screen, or one you name).
/// Prefers the offline file when the video is downloaded.
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

/// "Download this" — saves a video for offline playback.
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

/// "Add this to <playlist>" — saves a video to one of your playlists. Both the
/// video (often the on-screen one) and the playlist resolve as entities, so the
/// playlist name can be spoken right in the phrase.
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
