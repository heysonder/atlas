import SwiftUI
import SwiftData
import CoreSpotlight

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var app = app
        TabView(selection: searchAwareSelection) {
            Tab("Home", systemImage: "house.fill", value: AppModel.TabSelection.feed) {
                FeedView()
            }
            Tab("Library", systemImage: "square.stack.fill", value: AppModel.TabSelection.profile) {
                ProfileView()
            }
            Tab(value: AppModel.TabSelection.search, role: .search) {
                SearchView()
            }
        }
        .background {
            // The default full-screen player handles playback unless the user
            // has switched to the embedded player in Settings.
            if app.playerStyle == .fullscreen {
                VideoPlayerPresenter(request: $app.nowPlaying, app: app, modelContext: modelContext)
                    .frame(width: 0, height: 0)
            }
        }
        .fullScreenCover(item: embeddedRequest) { request in
            EmbeddedPlayerView(request: request, app: app, modelContext: modelContext)
        }
        // Siri / App Intents routing. `.task` catches an action set during a cold
        // launch (before onChange is attached); onChange catches the warm case.
        .task { consumePendingIntent() }
        .onChange(of: app.pendingIntent) { _, _ in consumePendingIntent() }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            playFromSpotlight(activity)
        }
        .alert("Local Library Temporarily Unavailable",
               isPresented: Binding {
                   app.persistenceRecoveryMessage != nil
               } set: { isPresented in
                   if !isPresented { app.persistenceRecoveryMessage = nil }
               }) {
            Button("OK") { app.persistenceRecoveryMessage = nil }
        } message: {
            Text(app.persistenceRecoveryMessage ?? "")
        }
    }

    // MARK: Siri / Spotlight handling

    private func consumePendingIntent() {
        guard let action = app.pendingIntent else { return }
        app.pendingIntent = nil
        switch action {
        case .search(let query):
            app.selectedTab = .search
            app.pendingSearchQuery = query
        case .resumeWatching:
            playMostRecentWatch()
        case .forYou:
            app.selectedTab = .feed
        case .openDownloads:
            app.selectedTab = .profile
            app.libraryTarget = .downloads
        }
    }

    /// Resume the most recent watch, preferring an offline copy when we have one.
    private func playMostRecentWatch() {
        var descriptor = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.watchedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let entry = try? modelContext.fetch(descriptor).first else { return }
        play(videoID: entry.videoID, title: entry.title,
             uploader: entry.uploader, thumbnail: entry.thumbnailURL)
    }

    /// A tapped Spotlight result hands us the namespaced item id; play it.
    private func playFromSpotlight(_ activity: NSUserActivity) {
        guard let itemID = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return }
        let videoID = SpotlightIndexer.videoID(fromItemID: itemID)
        let entry = try? modelContext.fetch(FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { $0.videoID == videoID })).first
        play(videoID: videoID, title: entry?.title ?? "Video",
             uploader: entry?.uploader, thumbnail: entry?.thumbnailURL)
    }

    /// Plays a video by id, swapping in the downloaded file when present so the
    /// player skips stream resolution and works offline.
    private func play(videoID: String, title: String, uploader: String?, thumbnail: String?) {
        let download = try? modelContext.fetch(FetchDescriptor<DownloadedVideo>(
            predicate: #Predicate { $0.videoID == videoID })).first
        if let download {
            app.playDownloaded(download)
        } else {
            app.nowPlaying = PlayRequest(videoID: videoID, title: title,
                                         uploader: uploader, thumbnail: thumbnail)
        }
    }

    /// Surfaces `nowPlaying` to the embedded player only when that style is
    /// selected, so exactly one player ever owns the current request.
    private var embeddedRequest: Binding<PlayRequest?> {
        Binding {
            app.playerStyle == .embedded ? app.nowPlaying : nil
        } set: { newValue in
            app.nowPlaying = newValue
        }
    }

    /// Wraps the tab selection so re-tapping the search tab while already on the
    /// search page bumps a token SearchView listens to (clear field + refocus).
    private var searchAwareSelection: Binding<AppModel.TabSelection> {
        Binding {
            app.selectedTab
        } set: { newValue in
            if newValue == .search && app.selectedTab == .search {
                app.searchRetapToken += 1
            }
            app.selectedTab = newValue
        }
    }
}
