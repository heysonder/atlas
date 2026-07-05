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

    @MainActor
    init(download: DownloadedVideo, fallbackThumbnail: String? = nil) {
        self.init(videoID: download.videoID,
                  title: download.title,
                  uploader: download.uploader,
                  thumbnail: download.thumbnailURL?.absoluteString ?? fallbackThumbnail,
                  localURL: download.fileURL,
                  localCaptionURL: download.captionURL,
                  localCaptionMimeType: download.captionMimeType)
    }
}

/// One transient item in the in-memory playback queue.
struct QueuedVideo: Identifiable, Hashable {
    let id: UUID
    let request: PlayRequest

    init(_ request: PlayRequest, id: UUID = UUID()) {
        self.id = id
        self.request = request
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
    /// Persisted instance api_url. Empty means the user has not opted into a
    /// Piped instance, so online surfaces must not create a network client.
    var instanceURLString: String {
        didSet { instanceStore.save(instanceURLString) }
    }

    @ObservationIgnored private let instanceStore: InstanceStore

    /// Set to present the player from anywhere.
    var nowPlaying: PlayRequest?

    /// Set when the persistent SwiftData store could not be opened and the app
    /// launched with temporary storage to avoid deleting the user's local data.
    var persistenceRecoveryMessage: String?

    /// Transient session queue. It intentionally is not persisted; closing the
    /// app clears it.
    var queuedVideos: [QueuedVideo] = []

    /// Which player UI handles `nowPlaying`. Defaults to the native full-screen
    /// player so existing behavior is unchanged.
    var playerStyle: PlayerStyle {
        didSet { UserDefaults.standard.set(playerStyle.rawValue, forKey: Self.playerStyleKey) }
    }
    static let playerStyleKey = "atlas.playerStyle"

    /// Shows an opt-in playback diagnostics HUD over the player.
    var statsForNerdsEnabled: Bool {
        didSet { UserDefaults.standard.set(statsForNerdsEnabled, forKey: Self.statsForNerdsKey) }
    }
    static let statsForNerdsKey = "atlas.player.statsForNerds"

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

    static let instanceKey = InstanceStore.defaultsKey
    nonisolated static let missingInstanceMessage = "Set a Piped instance in Settings before using online video features."

    init(persistenceRecoveryMessage: String? = nil, instanceStore: InstanceStore = .live) {
        let defaults = UserDefaults.standard
        self.instanceStore = instanceStore
        self.persistenceRecoveryMessage = persistenceRecoveryMessage
        hideShorts = defaults.bool(forKey: Self.hideShortsKey)
        shortsLayout = defaults.string(forKey: Self.shortsLayoutKey)
            .flatMap(ShortsLayout.init(rawValue:)) ?? .inline
        playerStyle = defaults.string(forKey: Self.playerStyleKey)
            .flatMap(PlayerStyle.init(rawValue:)) ?? .fullscreen
        statsForNerdsEnabled = defaults.bool(forKey: Self.statsForNerdsKey)
        // SponsorBlock defaults to on; absent key means a fresh install.
        sponsorBlockEnabled = defaults.object(forKey: Self.sponsorBlockKey) == nil
            ? true : defaults.bool(forKey: Self.sponsorBlockKey)
        if let raw = defaults.array(forKey: Self.sponsorCategoriesKey) as? [String] {
            sponsorCategories = Set(raw.compactMap(SponsorCategory.init(rawValue:)))
        } else {
            sponsorCategories = Self.defaultSponsorCategories
        }
        instanceURLString = instanceStore.load()
    }

    /// A client for the currently selected instance.
    var client: PipedClient {
        get throws {
            guard let client = PipedClient(instanceString: instanceURLString) else {
                throw AtlasNetworkError.missingPipedInstance
            }
            return client
        }
    }

    // MARK: Stream resolution cache (warms the slow /streams extraction)

    @ObservationIgnored private var streamCache: [String: (detail: VideoDetail, at: Date)] = [:]
    @ObservationIgnored private var inflight: [String: Task<VideoDetail, Error>] = [:]
    /// How long cached details are reused before re-fetching (one hour). Signed
    /// stream URLs stay valid for longer, so this is comfortably safe; playback
    /// failure recovery uses `refreshStream` when it suspects expiry.
    private static let streamTTL: TimeInterval = 3600
    /// Ceiling on cached details; the oldest entries are pruned past this.
    private static let streamCacheLimit = 48

    /// The cached detail for a video, when present and still within the TTL.
    private func cachedDetail(_ videoID: String) -> VideoDetail? {
        guard let cached = streamCache[videoID],
              Date().timeIntervalSince(cached.at) < Self.streamTTL else { return nil }
        return cached.detail
    }

    /// Returns the stream details, using a cached/in-flight result when available
    /// so a tap doesn't re-pay the full extraction latency.
    func resolveStream(_ videoID: String) async throws -> VideoDetail {
        if let cached = cachedDetail(videoID) { return cached }
        if let task = inflight[videoID] { return try await task.value }
        return try await startResolution(videoID).value
    }

    /// Starts a fetch and registers it in `inflight` *synchronously*, so a
    /// same-turn burst of callers (and the prefetch cap) sees it immediately.
    private func startResolution(_ videoID: String) throws -> Task<VideoDetail, Error> {
        let client = try self.client
        let task = Task<VideoDetail, Error> { try await client.streams(videoID: videoID) }
        inflight[videoID] = task
        Task {
            if let detail = try? await task.value {
                cacheDetail(detail, for: videoID)
            }
            inflight[videoID] = nil
        }
        return task
    }

    /// Inserts into the cache, pruning expired entries and trimming to the cap
    /// (oldest first) so the cache can't grow without bound over a long session.
    private func cacheDetail(_ detail: VideoDetail, for videoID: String) {
        let now = Date()
        streamCache = streamCache.filter { now.timeIntervalSince($0.value.at) < Self.streamTTL }
        while streamCache.count >= Self.streamCacheLimit,
              let oldest = streamCache.min(by: { $0.value.at < $1.value.at }) {
            streamCache.removeValue(forKey: oldest.key)
        }
        streamCache[videoID] = (detail, now)
    }

    // MARK: Row-driven resolution throttle

    @ObservationIgnored private var throttledResolutions = 0
    @ObservationIgnored private var throttleWaiters: [CheckedContinuation<Void, Never>] = []
    private static let throttledResolutionLimit = 2

    /// Like `resolveStream`, but bounded: at most a couple of row-driven
    /// resolutions run at once, so a scroll burst can't fan out an unbounded
    /// number of slow /streams extractions. Cache and in-flight hits return
    /// immediately without taking a slot; everything else queues FIFO.
    func resolveStreamThrottled(_ videoID: String) async throws -> VideoDetail {
        if let cached = cachedDetail(videoID) { return cached }
        if let task = inflight[videoID] { return try await task.value }
        await acquireThrottleSlot()
        defer { releaseThrottleSlot() }
        return try await resolveStream(videoID)
    }

    private func acquireThrottleSlot() async {
        if throttledResolutions < Self.throttledResolutionLimit {
            throttledResolutions += 1
            return
        }
        await withCheckedContinuation { throttleWaiters.append($0) }
    }

    private func releaseThrottleSlot() {
        if throttleWaiters.isEmpty {
            throttledResolutions -= 1
        } else {
            // Hand the slot straight to the next waiter.
            throttleWaiters.removeFirst().resume()
        }
    }

    /// Force-fetches fresh stream details, bypassing the cache. Playback
    /// failure recovery uses this when the signed URLs in the current details
    /// may have expired.
    func refreshStream(_ videoID: String) async throws -> VideoDetail {
        streamCache[videoID] = nil
        return try await resolveStream(videoID)
    }

    /// When the cached details for a video were actually fetched. A cache hit
    /// can be up to `streamTTL` old, so players must not date their copy from
    /// the moment `resolveStream` returned.
    func streamResolvedAt(_ videoID: String) -> Date? {
        streamCache[videoID]?.at
    }

    /// Warm the cache for a video that's likely to be tapped. Capped so we never
    /// fire more than a couple of extractions at the instance at once — the task
    /// registers in `inflight` synchronously, so a same-turn burst of calls
    /// can't slip past the cap.
    func prefetchStream(_ videoID: String?) {
        guard let videoID,
              cachedDetail(videoID) == nil,
              inflight[videoID] == nil,
              inflight.count < 2 else { return }
        _ = try? startResolution(videoID)
    }

    static func normalize(_ raw: String) -> String {
        InstanceStore.normalize(raw)
    }

    static func isValidInstanceURL(_ raw: String) -> Bool {
        InstanceStore.isValidInstanceURL(raw)
    }

    func play(_ item: StreamItem) {
        guard let request = PlayRequest(item: item) else { return }
        nowPlaying = request
    }

    func playNext(_ request: PlayRequest) {
        queuedVideos.insert(QueuedVideo(request), at: 0)
    }

    func addToQueue(_ request: PlayRequest) {
        queuedVideos.append(QueuedVideo(request))
    }

    func removeFromQueue(_ queued: QueuedVideo) -> PlayRequest? {
        guard let index = queuedVideos.firstIndex(where: { $0.id == queued.id }) else { return nil }
        return queuedVideos.remove(at: index).request
    }

    func moveQueuedVideos(from offsets: IndexSet, to destination: Int) {
        queuedVideos.move(fromOffsets: offsets, toOffset: destination)
    }

    func dequeueNext() -> PlayRequest? {
        guard !queuedVideos.isEmpty else { return nil }
        return queuedVideos.removeFirst().request
    }

    func clearQueue() {
        queuedVideos.removeAll()
    }

    func playPlaylistVideo(_ video: PlaylistVideo) {
        nowPlaying = PlayRequest(videoID: video.videoID, title: video.title,
                                 uploader: video.uploader, thumbnail: video.thumbnailURL)
    }

    func playDownloaded(_ video: DownloadedVideo) {
        nowPlaying = PlayRequest(download: video)
    }
}

enum AtlasNetworkError: LocalizedError {
    case missingPipedInstance

    var errorDescription: String? {
        switch self {
        case .missingPipedInstance:
            AppModel.missingInstanceMessage
        }
    }
}
