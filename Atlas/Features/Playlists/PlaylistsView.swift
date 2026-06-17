import SwiftUI
import SwiftData

struct PlaylistsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var hSize
    @Query(sort: \Playlist.createdAt, order: .reverse) private var playlists: [Playlist]

    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        Group {
            if playlists.isEmpty {
                ContentUnavailableView {
                    Label("No playlists", systemImage: "music.note.list")
                } description: {
                    Text("Create a playlist, then long-press any video to add it.")
                } actions: {
                    Button("New Playlist") { creating = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if hSize == .regular {
                AdaptiveGrid(minCardWidth: 300) {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            PlaylistRow(playlist: playlist).libraryCard()
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { context.delete(playlist) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } else {
                List {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            PlaylistRow(playlist: playlist)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New", systemImage: "plus") { creating = true }
            }
        }
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") { create() }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        context.insert(Playlist(name: name))
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { context.delete(playlists[index]) }
    }
}

/// One playlist as a horizontal row, shared by the iPhone `List` and iPad grid.
private struct PlaylistRow: View {
    let playlist: Playlist
    var body: some View {
        HStack(spacing: 12) {
            PlaylistThumb(playlist: playlist)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.body.weight(.medium)).lineLimit(1)
                Text("\(playlist.videos.count) video\(playlist.videos.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Small stacked-thumbnail preview of a playlist's first video.
private struct PlaylistThumb: View {
    let playlist: Playlist
    var body: some View {
        let first = playlist.orderedVideos.first
        Thumbnail(url: first?.thumbnailURL)
            .aspectRatio(16/9, contentMode: .fill)
            .frame(width: 84, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "music.note.list")
                    .font(.caption2)
                    .padding(3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(3)
            }
    }
}

struct PlaylistDetailView: View {
    @Bindable var playlist: Playlist

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        Group {
            if playlist.videos.isEmpty {
                ContentUnavailableView("Empty playlist", systemImage: "music.note.list",
                    description: Text("Long-press a video anywhere and choose Add to Playlist."))
            } else if hSize == .regular {
                AdaptiveGrid {
                    ForEach(playlist.orderedVideos) { video in
                        Button { app.playPlaylistVideo(video) } label: {
                            PlaylistVideoRow(video: video).libraryCard()
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            QueueMenuItems(request: playRequest(for: video))
                            Button(role: .destructive) { context.delete(video) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            } else {
                List {
                    ForEach(playlist.orderedVideos) { video in
                        Button { app.playPlaylistVideo(video) } label: {
                            PlaylistVideoRow(video: video)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            QueueMenuItems(request: playRequest(for: video))
                        }
                    }
                    .onDelete(perform: removeVideos)
                }
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func removeVideos(_ offsets: IndexSet) {
        let ordered = playlist.orderedVideos
        for index in offsets { context.delete(ordered[index]) }
    }

    private func playRequest(for video: PlaylistVideo) -> PlayRequest {
        PlayRequest(videoID: video.videoID, title: video.title,
                    uploader: video.uploader, thumbnail: video.thumbnailURL)
    }
}

/// One playlist video as a horizontal row, shared by the iPhone `List` and the
/// iPad card grid.
private struct PlaylistVideoRow: View {
    let video: PlaylistVideo
    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Thumbnail(url: video.thumbnailURL)
                    .aspectRatio(16/9, contentMode: .fill)
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                let d = Format.duration(video.duration)
                if !d.isEmpty {
                    Text(d).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: Capsule())
                        .foregroundStyle(.white).padding(5)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if let uploader = video.uploader {
                    Text(uploader).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
