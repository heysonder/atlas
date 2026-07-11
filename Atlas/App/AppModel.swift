import Foundation
import Observation
import PipedKit

typealias StreamResolver = @Sendable (PipedClient, String) async throws -> VideoDetail
typealias ManifestWarmer = @Sendable (URL) async throws -> Void

/// App-wide state: which instance we talk to, and what's currently playing.
@MainActor
@Observable
final class AppModel {
    /// Persisted instance api_url. Empty means the user has not opted into a
    /// Piped instance, so online surfaces must not create a network client.
    var instanceURLString: String {
        didSet {
            instanceStore.save(instanceURLString)
            guard oldValue != instanceURLString else { return }
            rotateInstanceGeneration()
        }
    }

    /// Changes whenever the selected Piped endpoint changes. Network-backed views
    /// include this in their load identity so old-instance results cannot apply.
    private(set) var instanceGeneration: UInt64 = 0

    @ObservationIgnored private let instanceStore: InstanceStore
    @ObservationIgnored private let streamResolver: StreamResolver
    @ObservationIgnored private let manifestWarmer: ManifestWarmer?
    @ObservationIgnored private var instanceNetworkContext: InstanceNetworkContext?
    @ObservationIgnored private var instancePipedClient: PipedClient?
    @ObservationIgnored private var instanceHTTPClient: PolicyHTTPClient?

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
    nonisolated static let missingInstanceMessage =
        "Set a Piped instance in Settings before using online video features."

    init(
        persistenceRecoveryMessage: String? = nil,
        instanceStore: InstanceStore = .live,
        streamResolver: @escaping StreamResolver = { client, videoID in
            try await client.streams(videoID: videoID)
        },
        manifestWarmer: ManifestWarmer? = nil
    ) {
        let defaults = UserDefaults.standard
        self.instanceStore = instanceStore
        self.streamResolver = streamResolver
        self.manifestWarmer = manifestWarmer
        self.persistenceRecoveryMessage = persistenceRecoveryMessage
        hideShorts = defaults.bool(forKey: Self.hideShortsKey)
        shortsLayout =
            defaults.string(forKey: Self.shortsLayoutKey)
            .flatMap(ShortsLayout.init(rawValue:)) ?? .inline
        playerStyle =
            defaults.string(forKey: Self.playerStyleKey)
            .flatMap(PlayerStyle.init(rawValue:)) ?? .fullscreen
        statsForNerdsEnabled = defaults.bool(forKey: Self.statsForNerdsKey)
        // SponsorBlock defaults to on; absent key means a fresh install.
        sponsorBlockEnabled =
            defaults.object(forKey: Self.sponsorBlockKey) == nil
            ? true : defaults.bool(forKey: Self.sponsorBlockKey)
        if let raw = defaults.array(forKey: Self.sponsorCategoriesKey) as? [String] {
            sponsorCategories = Set(raw.compactMap(SponsorCategory.init(rawValue:)))
        } else {
            sponsorCategories = Self.defaultSponsorCategories
        }
        instanceURLString = instanceStore.load()
        instanceNetworkContext = Self.makeNetworkContext(
            instanceURLString, generation: instanceGeneration)
        instancePipedClient = instanceNetworkContext.map { PipedClient(context: $0) }
        instanceHTTPClient = instanceNetworkContext.map { PolicyHTTPClient(context: $0) }
    }

    /// A client for the currently selected instance.
    var client: PipedClient {
        get throws {
            guard let instancePipedClient else {
                throw AtlasNetworkError.missingPipedInstance
            }
            return instancePipedClient
        }
    }

    var httpClient: PolicyHTTPClient {
        get throws {
            guard let instanceHTTPClient else {
                throw AtlasNetworkError.missingPipedInstance
            }
            return instanceHTTPClient
        }
    }

    nonisolated static let publicHTTPClient = PolicyHTTPClient(context: .publicInternet())

    // MARK: Stream resolution cache (warms the slow /streams extraction)

    private struct CachedStream {
        let generation: UInt64
        let detail: VideoDetail
        let at: Date
    }

    private struct InflightResolution {
        let id: UUID
        let generation: UInt64
        let task: Task<VideoDetail, Error>
    }

    @ObservationIgnored private var streamCache: [String: CachedStream] = [:]
    @ObservationIgnored private var inflight: [String: InflightResolution] = [:]
    /// How long cached details are reused before re-fetching (one hour). Signed
    /// stream URLs stay valid for longer, so this is comfortably safe; playback
    /// failure recovery uses `refreshStream` when it suspects expiry.
    private static let streamTTL: TimeInterval = 3600
    /// Ceiling on cached details; the oldest entries are pruned past this.
    private static let streamCacheLimit = 48

    /// The cached detail for a video, when present and still within the TTL.
    private func cachedDetail(_ videoID: String) -> VideoDetail? {
        guard let cached = streamCache[videoID],
            cached.generation == instanceGeneration,
            Date().timeIntervalSince(cached.at) < Self.streamTTL
        else { return nil }
        return cached.detail
    }

    /// Returns the stream details, using a cached/in-flight result when available
    /// so a tap doesn't re-pay the full extraction latency.
    ///
    /// Does NOT warm the AV1 HLS manifest: bulk metadata callers (recommendation
    /// ranking, row enrichment, downloads) resolve dozens of videos per pass, and
    /// each manifest warm costs the instance a full extraction — enough of them
    /// at once starves the video that's actually playing. Playback-likely paths
    /// use `resolveStreamForPlayback` / `prefetchStream`, which do warm.
    func resolveStream(_ videoID: String) async throws -> VideoDetail {
        let generation = instanceGeneration
        if let cached = cachedDetail(videoID) { return cached }
        let task: Task<VideoDetail, Error>
        if let active = inflight[videoID], active.generation == generation {
            task = active.task
        } else {
            task = try startResolution(videoID, warmingManifest: false).task
        }
        let detail = try await task.value
        try Task.checkCancellation()
        guard generation == instanceGeneration else { throw CancellationError() }
        return detail
    }

    /// Stream details for a video that is about to play: additionally warms the
    /// AV1 HLS manifest (even on a cache hit — a metadata resolution may have
    /// filled the cache without warming) so AVPlayer finds it hot.
    func resolveStreamForPlayback(_ videoID: String) async throws -> VideoDetail {
        if let client = try? client { warmAV1Manifest(videoID, client: client) }
        return try await resolveStream(videoID)
    }

    /// Starts a fetch and registers it in `inflight` *synchronously*, so a
    /// same-turn burst of callers (and the prefetch cap) sees it immediately.
    private func startResolution(
        _ videoID: String,
        warmingManifest: Bool
    ) throws -> InflightResolution {
        let generation = instanceGeneration
        let client = try self.client
        if warmingManifest { warmAV1Manifest(videoID, client: client) }
        let resolver = streamResolver
        let requestID = UUID()
        let task = Task<VideoDetail, Error> {
            let detail = try await resolver(client, videoID)
            try Task.checkCancellation()
            return detail
        }
        let active = InflightResolution(id: requestID, generation: generation, task: task)
        inflight[videoID] = active
        Task {
            let result = await task.result
            guard generation == instanceGeneration,
                inflight[videoID]?.id == requestID
            else { return }
            if case .success(let detail) = result {
                cacheDetail(detail, for: videoID, generation: generation)
            }
            inflight[videoID] = nil
        }
        return active
    }

    /// Inserts into the cache, pruning expired entries and trimming to the cap
    /// (oldest first) so the cache can't grow without bound over a long session.
    private func cacheDetail(_ detail: VideoDetail, for videoID: String, generation: UInt64) {
        guard generation == instanceGeneration else { return }
        let now = Date()
        streamCache = streamCache.filter { now.timeIntervalSince($0.value.at) < Self.streamTTL }
        while streamCache.count >= Self.streamCacheLimit,
            let oldest = streamCache.min(by: { $0.value.at < $1.value.at })
        {
            streamCache.removeValue(forKey: oldest.key)
        }
        streamCache[videoID] = CachedStream(generation: generation, detail: detail, at: now)
    }

    // MARK: AV1 HLS manifest warming
    //
    // The instance builds an /hls/av1 master manifest with a full extraction on
    // first request (5–20s measured) and serves repeats from a server-side
    // cache in ~0.1s, but AVPlayer only fetches the manifest *after* /streams
    // resolves — paying the two extractions back to back. Requesting the
    // manifest alongside a playback-likely /streams fetch runs them
    // concurrently, so by the time the player asks for it (on tap after a
    // prefetch, or a few seconds into a cold tap) the instance answers from
    // its warm cache. Only playback-likely paths warm: each warm is a full
    // extraction server-side, so bulk metadata resolution must never fan
    // these out.

    @ObservationIgnored private var manifestWarms: [URL: Date] = [:]
    private struct ManifestWarm {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var manifestWarmTasks: [URL: ManifestWarm] = [:]
    /// Re-warm after this long, in case the instance evicted its cached manifest.
    private static let manifestWarmTTL: TimeInterval = 15 * 60

    /// Fire-and-forget fetch of the AV1 HLS master manifest, deduped per URL so
    /// repeated resolutions don't re-trigger server-side extractions. Optimistic:
    /// it runs before /streams reveals whether the video has AV1 streams (the
    /// endpoint now builds a manifest from whatever codecs exist, so the warm
    /// work is useful whenever the player ends up on the HLS path).
    private func warmAV1Manifest(_ videoID: String, client: PipedClient) {
        guard StreamPlaybackBuilder.deviceSupportsAV1 else { return }
        let url = client.av1HLSMasterURL(videoID: videoID)
        let now = Date()
        if let warmedAt = manifestWarms[url],
            now.timeIntervalSince(warmedAt) < Self.manifestWarmTTL
        {
            return
        }
        manifestWarms = manifestWarms.filter {
            now.timeIntervalSince($0.value) < Self.manifestWarmTTL
        }
        manifestWarms[url] = now
        let generation = instanceGeneration
        let requestID = UUID()
        let warmer = manifestWarmer
        let httpClient = try? self.httpClient
        let task = Task(priority: .utility) {
            if let warmer {
                try? await warmer(url)
            } else if let httpClient {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 45
                _ = try? await httpClient.data(for: request)
            }
            try? Task.checkCancellation()
        }
        manifestWarmTasks[url] = ManifestWarm(
            id: requestID, generation: generation, task: task)
        Task {
            await task.value
            guard generation == instanceGeneration,
                manifestWarmTasks[url]?.id == requestID
            else { return }
            manifestWarmTasks[url] = nil
        }
    }

    // MARK: Row-driven resolution throttle

    private struct ThrottleWaiter {
        let id: UUID
        let generation: UInt64
        let continuation: CheckedContinuation<UUID?, Never>
    }
    @ObservationIgnored private var throttleLeases: Set<UUID> = []
    @ObservationIgnored private var throttleWaiters: [ThrottleWaiter] = []
    private static let throttledResolutionLimit = 2

    /// Like `resolveStream`, but bounded: at most a couple of row-driven
    /// resolutions run at once, so a scroll burst can't fan out an unbounded
    /// number of slow /streams extractions. Cache and in-flight hits return
    /// immediately without taking a slot; everything else queues FIFO.
    func resolveStreamThrottled(_ videoID: String) async throws -> VideoDetail {
        let generation = instanceGeneration
        if let cached = cachedDetail(videoID) { return cached }
        if let active = inflight[videoID], active.generation == generation {
            let detail = try await active.task.value
            try Task.checkCancellation()
            guard generation == instanceGeneration else { throw CancellationError() }
            return detail
        }
        guard let lease = await acquireThrottleSlot(generation: generation) else {
            throw CancellationError()
        }
        defer { releaseThrottleSlot(lease) }
        try Task.checkCancellation()
        guard generation == instanceGeneration else { throw CancellationError() }
        return try await resolveStream(videoID)
    }

    private func acquireThrottleSlot(generation: UInt64) async -> UUID? {
        guard !Task.isCancelled else { return nil }
        let lease = UUID()
        if throttleLeases.count < Self.throttledResolutionLimit {
            throttleLeases.insert(lease)
            return lease
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                throttleWaiters.append(
                    ThrottleWaiter(
                        id: lease, generation: generation, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelThrottleWaiter(lease)
            }
        }
    }

    private func cancelThrottleWaiter(_ lease: UUID) {
        if let index = throttleWaiters.firstIndex(where: { $0.id == lease }) {
            let waiter = throttleWaiters.remove(at: index)
            waiter.continuation.resume(returning: nil)
        } else if throttleLeases.contains(lease) {
            releaseThrottleSlot(lease)
        }
    }

    private func releaseThrottleSlot(_ lease: UUID) {
        guard throttleLeases.remove(lease) != nil else { return }
        while !throttleWaiters.isEmpty {
            let waiter = throttleWaiters.removeFirst()
            guard waiter.generation == instanceGeneration else {
                waiter.continuation.resume(returning: nil)
                continue
            }
            throttleLeases.insert(waiter.id)
            waiter.continuation.resume(returning: waiter.id)
            break
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
            inflight.count < 2
        else { return }
        _ = try? startResolution(videoID, warmingManifest: true)
    }

    private func rotateInstanceGeneration() {
        instanceGeneration &+= 1
        let generation = instanceGeneration
        Task { await ThumbnailPrefetcher.shared.reset(generation: generation) }
        for active in inflight.values { active.task.cancel() }
        inflight.removeAll()
        streamCache.removeAll()
        for warm in manifestWarmTasks.values { warm.task.cancel() }
        manifestWarmTasks.removeAll()
        manifestWarms.removeAll()
        throttleLeases.removeAll()
        let waiters = throttleWaiters
        throttleWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(returning: nil) }
        instanceNetworkContext = Self.makeNetworkContext(
            instanceURLString, generation: instanceGeneration)
        instancePipedClient = instanceNetworkContext.map { PipedClient(context: $0) }
        instanceHTTPClient = instanceNetworkContext.map { PolicyHTTPClient(context: $0) }
    }

    private static func makeNetworkContext(
        _ rawURL: String,
        generation: UInt64
    ) -> InstanceNetworkContext? {
        guard let url = URL(string: rawURL) else { return nil }
        return try? InstanceNetworkContext(instanceURL: url, generation: generation)
    }

    static func normalize(_ raw: String) -> String {
        InstanceStore.normalize(raw)
    }

    static func isValidInstanceURL(_ raw: String) -> Bool {
        InstanceStore.isValidInstanceURL(raw)
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
