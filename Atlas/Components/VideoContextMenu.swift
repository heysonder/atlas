import SwiftUI
import SwiftData
import PipedKit

/// The long-press menu shown on a video card: download for offline viewing and
/// add to a playlist. Shared by every card list via `.videoContextMenu(item)`.
///
/// The playlist list, thumbs state and download entry are fetched lazily when
/// the menu is actually opened — cheap point lookups per presentation — so the
/// card lists don't have to run live whole-table queries on every body
/// evaluation just to feed a menu that's rarely shown.
struct VideoContextMenu: ViewModifier {
    let item: StreamItem

    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.modelContext) private var context
    @AppStorage(FeedMode.storageKey) private var feedMode: FeedMode = .subscriptions
    @State private var creatingNew = false
    @State private var newName = ""

    /// What the menu needs to render, resolved at menu-open time.
    private struct MenuData {
        var playlists: [Playlist] = []
        /// Current thumbs state for this video: +1, −1, or 0.
        var signal = 0
        var download: DownloadedVideo?
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if item.isVideo {
                    let data = fetchMenuData()
                    if feedMode.isPersonalized { feedbackButtons(currentSignal: data.signal); Divider() }
                    queueButtons(download: data.download)
                    Divider()
                    downloadButton(download: data.download)
                    Menu("Add to Playlist", systemImage: "text.badge.plus") {
                        Button("New Playlist…", systemImage: "plus") { creatingNew = true }
                        if !data.playlists.isEmpty { Divider() }
                        ForEach(data.playlists) { playlist in
                            Button(playlist.name) { add(to: playlist) }
                        }
                    }
                }
            }
            .alert("New Playlist", isPresented: $creatingNew) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create") { createAndAdd() }
            }
    }

    /// One targeted fetch per menu presentation: all playlists (small table)
    /// plus this video's feedback and download rows by unique id.
    private func fetchMenuData() -> MenuData {
        var data = MenuData()
        data.playlists = (try? context.fetch(FetchDescriptor<Playlist>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        guard let videoID = item.videoID else { return data }
        data.signal = FeedbackStore.signal(for: videoID, in: context)
        var downloadFetch = FetchDescriptor<DownloadedVideo>(
            predicate: #Predicate { $0.videoID == videoID })
        downloadFetch.fetchLimit = 1
        data.download = (try? context.fetch(downloadFetch))?.first
        return data
    }

    /// "Suggest more / less" — each toggles off if it's already the current state.
    @ViewBuilder private func feedbackButtons(currentSignal sig: Int) -> some View {
        Button("Suggest More",
               systemImage: sig > 0 ? "hand.thumbsup.fill" : "hand.thumbsup") {
            FeedbackStore.set(sig > 0 ? 0 : 1, for: item, in: context)
        }
        Button("Suggest Less",
               systemImage: sig < 0 ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
            FeedbackStore.set(sig < 0 ? 0 : -1, for: item, in: context)
        }
    }

    @ViewBuilder private func queueButtons(download: DownloadedVideo?) -> some View {
        if let request = playRequest(download: download) {
            QueueMenuItems(request: request)
        }
    }

    @ViewBuilder private func downloadButton(download: DownloadedVideo?) -> some View {
        if let videoID = item.videoID {
            if download != nil {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    downloads.remove(videoID)
                }
            } else if downloads.isInFlight(videoID) {
                Button("Downloading…", systemImage: "arrow.down.circle") {}
                    .disabled(true)
            } else {
                Button("Download", systemImage: "arrow.down.circle") {
                    downloads.download(item, using: app)
                }
            }
        }
    }

    private func playRequest(download: DownloadedVideo?) -> PlayRequest? {
        guard let request = PlayRequest(item: item) else { return nil }
        guard let download else { return request }
        return PlayRequest(download: download, fallbackThumbnail: request.thumbnail)
    }

    private func add(to playlist: Playlist) {
        guard let snapshot = PlaylistVideoSnapshot(item: item) else { return }
        PlaylistStore.add(snapshot, to: playlist, in: context)
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        guard let playlist = PlaylistStore.createPlaylist(named: name, in: context) else { return }
        add(to: playlist)
    }
}

extension View {
    /// Adds the long-press card menu (download + add to playlist) for a video.
    func videoContextMenu(_ item: StreamItem) -> some View {
        modifier(VideoContextMenu(item: item))
    }
}
