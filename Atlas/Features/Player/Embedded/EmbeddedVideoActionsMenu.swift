import SwiftData
import SwiftUI

/// The "…" menu on the embedded watch page: For You feedback (when the
/// personalized feed is on) and add-to-playlist. Mirrors the full-screen Info
/// sheet's menu, which stays untouched.
struct EmbeddedVideoActionsMenu: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Playlist.createdAt, order: .reverse) private var playlists: [Playlist]

    let videoID: String
    let title: String
    let uploader: String?
    let thumbnail: String?
    let duration: Int?
    let showFeedback: Bool
    @Binding var feedback: Int
    let onFeedback: (Int) -> Bool

    @State private var creatingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var playlistError: String?

    var body: some View {
        Menu {
            if showFeedback {
                feedbackButton(more: true)
                feedbackButton(more: false)
                Divider()
            }
            Button("New Playlist…", systemImage: "plus") { creatingPlaylist = true }
            if !playlists.isEmpty { Divider() }
            ForEach(playlists) { playlist in
                let contains = PlaylistStore.containsVideoID(videoID, in: playlist)
                Button {
                    add(to: playlist)
                } label: {
                    Label(
                        PlaylistStore.displayName(for: playlist, among: playlists),
                        systemImage: contains ? "checkmark" : "music.note.list")
                }
                .disabled(contains)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("More video actions")
        .alert("New Playlist", isPresented: $creatingPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") { createAndAdd() }
                .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "Playlist Not Updated",
            isPresented: Binding(
                get: { playlistError != nil },
                set: { if !$0 { playlistError = nil } })
        ) {
            Button("OK", role: .cancel) { playlistError = nil }
        } message: {
            Text(playlistError ?? "")
        }
    }

    @ViewBuilder private func feedbackButton(more: Bool) -> some View {
        let active = more ? feedback > 0 : feedback < 0
        let target = more ? 1 : -1
        Button {
            let requested = (feedback == target) ? 0 : target
            feedback = PlayerInfoPersistence.retainedValue(
                current: feedback, requested: requested, persist: onFeedback)
        } label: {
            Label(
                more ? "Suggest More" : "Suggest Less",
                systemImage: more
                    ? (active ? "hand.thumbsup.fill" : "hand.thumbsup")
                    : (active ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
        }
        .accessibilityValue(active ? "Selected" : "Not selected")
    }

    private var snapshot: PlaylistVideoSnapshot {
        PlaylistVideoSnapshot(
            videoID: videoID, title: title, uploader: uploader,
            thumbnailURL: thumbnail, duration: duration ?? 0)
    }

    private func add(to playlist: Playlist) {
        if PlaylistStore.add(snapshot, to: playlist, in: context) == .missing {
            playlistError = "Atlas couldn’t add this video. Check available storage and try again."
        }
    }

    private func createAndAdd() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        newPlaylistName = ""
        guard !name.isEmpty else { return }
        if PlaylistStore.createPlaylist(named: name, adding: snapshot, in: context) != .added {
            playlistError =
                "Atlas couldn’t create that playlist. The name may already exist or a storage limit was reached."
        }
    }
}
