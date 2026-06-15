import SwiftUI
import SwiftData
import AVFoundation
import AppIntents

@main
struct AtlasApp: App {
    @State private var app: AppModel
    @State private var downloads: DownloadManager
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer

    init() {
        Self.configureURLCache()
        let container = Self.makeModelContainer()
        modelContainer = container
        let appModel = AppModel()
        let downloadManager = DownloadManager(modelContext: container.mainContext)
        _app = State(initialValue: appModel)
        _downloads = State(initialValue: downloadManager)
        configureAudioSession()

        // Wire Siri / App Intents: give intents access to the store and the live
        // app + download manager, then publish downloads & history to Spotlight.
        IntentDataStore.injectedContainer = container
        IntentDataStore.app = appModel
        AppDependencyManager.shared.add(dependency: appModel)
        AppDependencyManager.shared.add(dependency: downloadManager)
        Task { @MainActor in SpotlightIndexer.reindexAll() }
    }

    /// Give the shared cache (used by `AsyncImage` and the thumbnail prefetcher)
    /// enough room to hold a deep scroll's worth of thumbnails, so prefetched
    /// images survive until their rows scroll into view instead of being evicted.
    private static func configureURLCache() {
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(downloads)
        }
        .modelContainer(modelContainer)
    }

    /// Builds the SwiftData container, self-healing if the on-disk store can't be
    /// loaded or migrated (e.g. after a schema change). Worst case we reset local
    /// data — all of it is re-fetchable, so this can never brick the app.
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([SubscribedChannel.self, HistoryEntry.self, Playlist.self,
                             PlaylistVideo.self, DownloadedVideo.self, Feedback.self,
                             SearchEntry.self, VideoSignalCacheEntry.self,
                             RecommendationProfileSnapshot.self])
        let config = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Migration/incompatibility: delete the store and start fresh.
            let url = config.url
            for path in [url.path, url.path + "-wal", url.path + "-shm"] {
                try? FileManager.default.removeItem(atPath: path)
            }
            return (try? ModelContainer(for: schema, configurations: [config]))
                ?? { fatalError("Unrecoverable SwiftData error: \(error)") }()
        }
    }

    /// Allow audio to keep playing in the background and during Picture-in-Picture.
    /// Done off the main thread — `setActive` can block and risk a UI hang.
    private func configureAudioSession() {
        Task.detached(priority: .utility) {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } catch {
                // Non-fatal: playback still works in the foreground.
            }
        }
    }
}
