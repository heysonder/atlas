import SwiftUI
import PipedKit

/// A request to open the full-screen player. Carries enough to show a header
/// immediately while the full stream details load.
struct PlayRequest: Identifiable, Hashable {
    let videoID: String
    let title: String
    let uploader: String?
    let thumbnail: String?
    /// When set, the player plays this local file directly and skips the network
    /// stream resolution entirely (offline playback of a download).
    let localURL: URL?
    /// Optional local caption file saved next to a downloaded video.
    let localCaptionURL: URL?
    let localCaptionMimeType: String?
    var id: String { videoID }

    nonisolated init(videoID: String, title: String, uploader: String? = nil,
                     thumbnail: String? = nil, localURL: URL? = nil,
                     localCaptionURL: URL? = nil, localCaptionMimeType: String? = nil) {
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
        self.thumbnail = thumbnail
        self.localURL = localURL
        self.localCaptionURL = localCaptionURL
        self.localCaptionMimeType = localCaptionMimeType
    }

    nonisolated init?(item: StreamItem) {
        guard let videoID = item.videoID else { return nil }
        self.init(videoID: videoID,
                  title: item.displayTitle,
                  uploader: item.uploaderName,
                  thumbnail: item.thumbnail)
    }
}

/// Which player UI opens when you tap a video. The native full-screen player is
/// the default; the embedded option plays inline with the info panel beneath it.
enum PlayerStyle: String, CaseIterable, Identifiable {
    case fullscreen
    case embedded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullscreen: "Fullscreen"
        case .embedded: "Embedded"
        }
    }

    var blurb: String {
        switch self {
        case .fullscreen:
            "Tapping a video opens the native full-screen player; tap ⓘ for details."
        case .embedded:
            "Tapping a video opens an inline player with the channel, description, and comments scrolling beneath it."
        }
    }
}

/// App-wide state: which instance we talk to, and what's currently playing.
@MainActor
@Observable
final class AppModel {
    /// Persisted instance api_url. Defaults to a reachable public instance;
    /// override in Settings (including your own self-hosted instance).
    var instanceURLString: String {
        didSet { UserDefaults.standard.set(instanceURLString, forKey: Self.instanceKey) }
    }

    /// Set to present the player from anywhere.
    var nowPlaying: PlayRequest?

    /// Which player UI handles `nowPlaying`. Defaults to the native full-screen
    /// player so existing behavior is unchanged.
    var playerStyle: PlayerStyle {
        didSet { UserDefaults.standard.set(playerStyle.rawValue, forKey: Self.playerStyleKey) }
    }
    static let playerStyleKey = "atlas.playerStyle"

    /// When on, YouTube Shorts are hidden from the feed, search, and channels.
    var hideShorts: Bool {
        didSet { UserDefaults.standard.set(hideShorts, forKey: Self.hideShortsKey) }
    }
    static let hideShortsKey = "atlas.hideShorts"

    /// How shown Shorts are arranged in the Home feed (ignored when `hideShorts`).
    var shortsLayout: ShortsLayout {
        didSet { UserDefaults.standard.set(shortsLayout.rawValue, forKey: Self.shortsLayoutKey) }
    }
    static let shortsLayoutKey = "atlas.shortsLayout"

    /// Drops Shorts from a list when the user has chosen to hide them.
    func filteringShorts(_ items: [StreamItem]) -> [StreamItem] {
        hideShorts ? items.filter { $0.isShort != true } : items
    }

    // MARK: SponsorBlock

    /// Master switch for SponsorBlock. On by default; the player shows a "Skip"
    /// button over the video when a segment in an enabled category plays.
    var sponsorBlockEnabled: Bool {
        didSet { UserDefaults.standard.set(sponsorBlockEnabled, forKey: Self.sponsorBlockKey) }
    }
    static let sponsorBlockKey = "atlas.sponsorBlock.enabled"

    /// Which categories produce a skip prompt. Defaults to the sponsor-focused set.
    private(set) var sponsorCategories: Set<SponsorCategory> {
        didSet {
            UserDefaults.standard.set(
                sponsorCategories.map(\.rawValue), forKey: Self.sponsorCategoriesKey)
        }
    }
    static let sponsorCategoriesKey = "atlas.sponsorBlock.categories"
    static let defaultSponsorCategories: Set<SponsorCategory> = [.sponsor, .selfpromo, .interaction]

    func isSponsorCategoryEnabled(_ category: SponsorCategory) -> Bool {
        sponsorCategories.contains(category)
    }

    func setSponsorCategory(_ category: SponsorCategory, enabled: Bool) {
        if enabled { sponsorCategories.insert(category) } else { sponsorCategories.remove(category) }
    }

    /// The category ids to actually request for playback — empty when the
    /// feature is off, so the player skips the network call entirely.
    var activeSponsorCategoryIDs: [String] {
        sponsorBlockEnabled ? sponsorCategories.map(\.rawValue) : []
    }

    /// The selected bottom tab.
    enum TabSelection: Hashable { case feed, profile, search }
    var selectedTab: TabSelection = .feed

    /// Bumped each time the search tab is tapped while already on the search
    /// page, so SearchView can clear the field and refocus the keyboard.
    var searchRetapToken = 0

    // MARK: Siri / App Intents routing

    /// A deferred action from Siri or an App Shortcut. Set by an `AppIntent`,
    /// consumed and cleared by `RootView` once the UI is alive.
    var pendingIntent: AtlasIntentAction?

    /// A query Siri / a Shortcut asked us to run. `SearchView` watches this,
    /// fills its field, runs the search, then clears it.
    var pendingSearchQuery: String?

    /// A Library sub-screen to deep-link into. `ProfileView` watches this and
    /// pushes the matching route, then clears it.
    var libraryTarget: LibraryTarget?

    static let instanceKey = "atlas.instanceURL"
    static let defaultInstance = "https://api.piped.private.coffee"

    /// The bundled default before this build pointed at api.piped.private.coffee.
    private static let previousDefault = "https://pipedapi.cmf.sh"
    /// Set once we've performed the one-time switch onto the new default, so we
    /// never override a user who deliberately picks their own instance later.
    private static let switchedDefaultKey = "atlas.switchedToPrivateCoffee"

    init() {
        let defaults = UserDefaults.standard
        hideShorts = defaults.bool(forKey: Self.hideShortsKey)
        shortsLayout = defaults.string(forKey: Self.shortsLayoutKey)
            .flatMap(ShortsLayout.init(rawValue:)) ?? .inline
        playerStyle = defaults.string(forKey: Self.playerStyleKey)
            .flatMap(PlayerStyle.init(rawValue:)) ?? .fullscreen
        // SponsorBlock defaults to on; absent key means a fresh install.
        sponsorBlockEnabled = defaults.object(forKey: Self.sponsorBlockKey) == nil
            ? true : defaults.bool(forKey: Self.sponsorBlockKey)
        if let raw = defaults.array(forKey: Self.sponsorCategoriesKey) as? [String] {
            sponsorCategories = Set(raw.compactMap(SponsorCategory.init(rawValue:)))
        } else {
            sponsorCategories = Self.defaultSponsorCategories
        }
        var normalized = (defaults.string(forKey: Self.instanceKey)).map(Self.normalize)

        // One-time: move installs still sitting on the old bundled default onto
        // the new one. Guarded by a flag so switching back to your own instance
        // (e.g. a self-hosted box) in Settings sticks and isn't re-overridden.
        if !defaults.bool(forKey: Self.switchedDefaultKey) {
            if normalized == nil || normalized == Self.previousDefault {
                normalized = Self.defaultInstance
            }
            defaults.set(true, forKey: Self.switchedDefaultKey)
        }

        let resolved = normalized ?? Self.defaultInstance
        instanceURLString = resolved
        // Self-heal a previously-saved value that was missing its scheme.
        defaults.set(resolved, forKey: Self.instanceKey)
    }

    /// A client for the currently selected instance.
    var client: PipedClient {
        PipedClient(instanceString: instanceURLString)
            ?? PipedClient(baseURL: URL(string: Self.defaultInstance)!)
    }

    // MARK: Stream resolution cache (warms the slow /streams extraction)

    @ObservationIgnored private var streamCache: [String: (detail: VideoDetail, at: Date)] = [:]
    @ObservationIgnored private var inflight: [String: Task<VideoDetail, Error>] = [:]
    private static let streamTTL: TimeInterval = 300

    /// Returns the stream details, using a cached/in-flight result when available
    /// so a tap doesn't re-pay the full extraction latency.
    func resolveStream(_ videoID: String) async throws -> VideoDetail {
        if let cached = streamCache[videoID], Date().timeIntervalSince(cached.at) < Self.streamTTL {
            return cached.detail
        }
        if let task = inflight[videoID] { return try await task.value }
        let task = Task<VideoDetail, Error> { try await client.streams(videoID: videoID) }
        inflight[videoID] = task
        do {
            let detail = try await task.value
            inflight[videoID] = nil
            streamCache[videoID] = (detail, Date())
            return detail
        } catch {
            inflight[videoID] = nil
            throw error
        }
    }

    /// Warm the cache for a video that's likely to be tapped. Capped so we never
    /// fire more than a couple of extractions at the instance at once.
    func prefetchStream(_ videoID: String?) {
        guard let videoID,
              streamCache[videoID] == nil,
              inflight[videoID] == nil,
              inflight.count < 2 else { return }
        Task { _ = try? await resolveStream(videoID) }
    }

    /// Ensures an instance string is a usable absolute URL:
    /// trims whitespace, drops a trailing slash, and adds `https://` when no scheme is present.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return defaultInstance }
        if s.hasSuffix("/") { s.removeLast() }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = "https://" + s
        }
        return s
    }

    func play(_ item: StreamItem) {
        guard let request = PlayRequest(item: item) else { return }
        nowPlaying = request
    }

    func playPlaylistVideo(_ video: PlaylistVideo) {
        nowPlaying = PlayRequest(videoID: video.videoID, title: video.title,
                                 uploader: video.uploader, thumbnail: video.thumbnailURL)
    }

    func playDownloaded(_ video: DownloadedVideo) {
        nowPlaying = PlayRequest(videoID: video.videoID, title: video.title,
                                 uploader: video.uploader,
                                 thumbnail: video.thumbnailURL?.absoluteString,
                                 localURL: video.fileURL,
                                 localCaptionURL: video.captionURL,
                                 localCaptionMimeType: video.captionMimeType)
    }
}
