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
        let containerResult = Self.makeModelContainer()
        modelContainer = containerResult.container
        let appModel = AppModel(persistenceRecoveryMessage: containerResult.recoveryMessage)
        let downloadManager = DownloadManager(modelContext: modelContainer.mainContext)
        _app = State(initialValue: appModel)
        _downloads = State(initialValue: downloadManager)
        configureAudioSession()

        // Wire Siri / App Intents: give intents access to the store and the live
        // app + download manager, then publish downloads & history to Spotlight.
        IntentDataStore.injectedContainer = modelContainer
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

    private struct ModelContainerResult {
        let container: ModelContainer
        let recoveryMessage: String?
    }

    /// Builds the SwiftData container without deleting the user's persistent
    /// store. If the on-disk store cannot be opened, launch against temporary
    /// in-memory storage and surface the problem so the saved data remains
    /// available for migration/backup recovery instead of being silently wiped.
    private static func makeModelContainer() -> ModelContainerResult {
        let schema = Schema([SubscribedChannel.self, HistoryEntry.self, Playlist.self,
                             PlaylistVideo.self, DownloadedVideo.self, Feedback.self,
                             SearchEntry.self, VideoSignalCacheEntry.self,
                             RecommendationProfileSnapshot.self])
        let config = ModelConfiguration(schema: schema)
        do {
            return ModelContainerResult(
                container: try ModelContainer(for: schema, configurations: [config]),
                recoveryMessage: nil)
        } catch {
            let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            if let fallback = try? ModelContainer(for: schema, configurations: [memoryConfig]) {
                return ModelContainerResult(
                    container: fallback,
                    recoveryMessage: "Atlas could not open its saved library, so it started with temporary storage. Your existing on-device data was left untouched.")
            }
            fatalError("Unrecoverable SwiftData error: \(error)")
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
