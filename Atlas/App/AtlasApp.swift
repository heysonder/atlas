import AVFoundation
import AppIntents
import SwiftData
import SwiftUI

@main
struct AtlasApp: App {
    @UIApplicationDelegateAdaptor(AtlasApplicationDelegate.self) private var applicationDelegate
    @State private var app: AppModel
    @State private var downloads: DownloadManager
    @State private var cloudSync: CloudSyncCoordinator
    private let modelContainer: ModelContainer

    init() {
        Self.configureURLCache()
        let containerResult = Self.makeModelContainer()
        modelContainer = containerResult.container
        let appModel = AppModel(persistenceRecoveryMessage: containerResult.recoveryMessage)
        let downloadManager = DownloadManager(
            modelContext: modelContainer.mainContext,
            storageMode: containerResult.downloadStorageMode)
        _app = State(initialValue: appModel)
        _downloads = State(initialValue: downloadManager)
        let sync = CloudSyncCoordinator(
            context: modelContainer.mainContext,
            persistenceAvailable: containerResult.recoveryMessage == nil)
        _cloudSync = State(initialValue: sync)
        AtlasApplicationDelegate.cloudSync = sync
        if containerResult.recoveryMessage == nil {
            SyncPreferences.attach(app: appModel, in: modelContainer.mainContext)
            // Older installs keep a Favorites row under a random ID; fold it into
            // the canonical one before any view can bind to it.
            PlaylistStore.adoptLegacyFavoritesIfNeeded(in: modelContainer.mainContext)
        }
        configureAudioSession()
        AppDiagnostics.start()

        // Wire Siri / App Intents: give intents access to the store and the live
        // app + download manager, then publish downloads & history to Spotlight.
        IntentDataStore.injectedContainer = modelContainer
        IntentDataStore.app = appModel
        AppDependencyManager.shared.add(dependency: appModel)
        AppDependencyManager.shared.add(dependency: downloadManager)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            SpotlightIndexer.reindexAll()
        }
    }

    /// Give the shared cache (used by the policy-aware image pipeline and prefetcher)
    /// enough room to hold a deep scroll's worth of thumbnails, so prefetched
    /// images survive until their rows scroll into view instead of being evicted.
    private static func configureURLCache() {
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024)
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(downloads)
                .environment(cloudSync)
                .task { await cloudSync.startIfEnrolled() }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase, initial: true) { _, phase in
            AppDiagnostics.sceneDidChange(active: phase == .active)
            if phase == .active {
                Task { await cloudSync.sceneActive() }
            } else {
                cloudSync.sceneInactive()
            }
        }
    }

    private struct ModelContainerResult {
        let container: ModelContainer
        let recoveryMessage: String?
        let downloadStorageMode: DownloadStorageMode
    }

    /// Builds the SwiftData container without deleting the user's persistent
    /// store. If the on-disk store cannot be opened, launch against temporary
    /// in-memory storage and surface the problem so the saved data remains
    /// available for migration/backup recovery instead of being silently wiped.
    private static func makeModelContainer() -> ModelContainerResult {
        do {
            return ModelContainerResult(
                container: try AtlasContainerFactory.make(),
                recoveryMessage: nil,
                downloadStorageMode: .persistent)
        } catch {
            if let fallback = try? AtlasContainerFactory.make(inMemory: true) {
                return ModelContainerResult(
                    container: fallback,
                    recoveryMessage:
                        "Atlas could not open its saved library, so it started with temporary storage. Your existing on-device data was left untouched.",
                    downloadStorageMode: .recoveryReadOnly)
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
