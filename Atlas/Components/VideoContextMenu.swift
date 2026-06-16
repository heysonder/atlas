import SwiftUI
import SwiftData
import PipedKit

/// The long-press menu shown on a video card: download for offline viewing and
/// add to a playlist. Shared by every card list via `.videoContextMenu(item)`.
struct VideoContextMenu: ViewModifier {
    let item: StreamItem

    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.modelContext) private var context
    @AppStorage("feedMode") private var feedMode: FeedMode = .subscriptions
    @Query(sort: \Playlist.createdAt, order: .reverse) private var playlists: [Playlist]
    @Query private var feedback: [Feedback]
    @State private var creatingNew = false
    @State private var newName = ""

    /// Current thumbs state for this video: +1, −1, or 0.
    private var currentSignal: Int {
        feedback.first { $0.videoID == item.videoID }?.signal ?? 0
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if item.isVideo {
                    if feedMode.isPersonalized { feedbackButtons; Divider() }
                    queueButtons
                    Divider()
                    downloadButton
                    Menu("Add to Playlist", systemImage: "text.badge.plus") {
                        Button("New Playlist…", systemImage: "plus") { creatingNew = true }
                        if !playlists.isEmpty { Divider() }
                        ForEach(playlists) { playlist in
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

    /// "Suggest more / less" — each toggles off if it's already the current state.
    @ViewBuilder private var feedbackButtons: some View {
        let sig = currentSignal
        Button("Suggest More",
               systemImage: sig > 0 ? "hand.thumbsup.fill" : "hand.thumbsup") {
            FeedbackStore.set(sig > 0 ? 0 : 1, for: item, in: context)
        }
        Button("Suggest Less",
               systemImage: sig < 0 ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
            FeedbackStore.set(sig < 0 ? 0 : -1, for: item, in: context)
        }
    }

    @ViewBuilder private var queueButtons: some View {
        if let request = playRequest {
            QueueMenuItems(request: request)
        }
    }

    @ViewBuilder private var downloadButton: some View {
        if let videoID = item.videoID {
            if downloads.isDownloaded(videoID) {
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

    private var playRequest: PlayRequest? {
        guard let request = PlayRequest(item: item) else { return nil }
        let videoID = request.videoID
        let descriptor = FetchDescriptor<DownloadedVideo>(
            predicate: #Predicate { $0.videoID == videoID })
        guard let download = try? context.fetch(descriptor).first else { return request }
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
