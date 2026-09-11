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

/// "Open <channel> in Atlas" — also what Spotlight runs when a subscribed
/// channel result is tapped (it's the `OpenIntent` for `ChannelEntity`).
struct OpenChannelIntent: AppIntent, OpenIntent {
    static let title: LocalizedStringResource = "Open Channel"
    static let description = IntentDescription("Open a channel you're subscribed to.")
    static let openAppWhenRun = true

    @Parameter(title: "Channel") var target: ChannelEntity

    @Dependency var app: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        let id = target.id
        await MainActor.run { app.pendingIntent = .openChannel(id) }
        return .result()
    }
}

/// "Play the latest from <channel>" — fetches the channel's newest upload and
/// plays it. Works as a spoken Siri command and as a Shortcuts building block.
struct PlayLatestFromChannelIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Latest From Channel"
    static let description = IntentDescription("Play the newest video from a channel you follow.")
    static let openAppWhenRun = true

    @Parameter(title: "Channel") var channel: ChannelEntity

    @Dependency var app: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Play the latest from \(\.$channel)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let video = await IntentDataStore.latestVideo(fromChannel: channel.id) else {
            return .result(dialog: "I couldn't find a recent video from \(channel.name).")
        }
        let request = PlayRequest(
            videoID: video.id, title: video.title, uploader: video.uploader,
            thumbnail: video.thumbnail, localURL: nil)
        await MainActor.run { app.nowPlaying = request }
        return .result(dialog: "Playing \(video.title).")
    }
}

/// Opens the Library → Playlists screen; the `OpenIntent` Spotlight runs when a
/// playlist result is tapped.
struct OpenPlaylistIntent: AppIntent, OpenIntent {
    static let title: LocalizedStringResource = "Open Playlist"
    static let description = IntentDescription("Open one of your playlists.")
    static let openAppWhenRun = true

    @Parameter(title: "Playlist") var target: PlaylistEntity

    @Dependency var app: AppModel

    func perform() async throws -> some IntentResult {
        await MainActor.run { app.pendingIntent = .openPlaylists }
        return .result()
    }
}

/// System search schema (Apple Intelligence / Spotlight "Search Atlas for …").
/// Kept separate from `ShowSearchResultsIntent` so the existing phrases and
/// Shortcuts keep their `String` parameter.
@AppIntent(schema: .system.search)
struct AtlasSystemSearchIntent: ShowInAppSearchResultsIntent {
    static let searchScopes: [StringSearchScope] = [.general]

    @Parameter var criteria: StringSearchCriteria

    @Dependency var app: AppModel

    func perform() async throws -> some IntentResult {
        let query = criteria.term
        await MainActor.run { app.pendingIntent = .search(query) }
        return .result()
    }
}

/// Lets Spotlight / Shortcuts turn typed text straight into video values
/// (iOS 26+ `IntentValueQuery`): "Atlas: <query>" offers matching videos to
/// play or add without opening the app first.
struct VideoValueQuery: IntentValueQuery {
    @MainActor
    func values(for input: String) async throws -> [VideoEntity] {
        await IntentDataStore.searchVideos(input, limit: 8)
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
struct PlayVideoIntent: AppIntent, OpenIntent {
    static let title: LocalizedStringResource = "Play Video"
    static let description = IntentDescription("Play a video in Atlas.")
    static let openAppWhenRun = true

    @Parameter(title: "Video") var target: VideoEntity

    @Dependency var app: AppModel

    func perform() async throws -> some IntentResult {
        // Prefer the offline file, but only when it actually exists — a stale
        // entity reference must fall back to network stream resolution.
        let localURL = target.localFileName
            .flatMap { DownloadStore.fileURL($0, expected: [.media]) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let request = PlayRequest(
            videoID: target.id, title: target.title, uploader: target.uploader,
            thumbnail: target.thumbnail,
            localURL: localURL)
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
            downloads.download(
                videoID: target.id, title: target.title,
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
