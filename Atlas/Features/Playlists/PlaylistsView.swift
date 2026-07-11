import SwiftData
import SwiftUI

struct PlaylistsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Playlist.createdAt, order: .reverse) private var playlists: [Playlist]

    @State private var creating = false
    @State private var newName = ""
    @State private var creationError: String?

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
            } else if horizontalSizeClass == .regular {
                AdaptiveGrid(minCardWidth: 300) {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            PlaylistRow(playlist: playlist).libraryCard()
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                PlaylistStore.delete(playlist, in: modelContext)
                            } label: {
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
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "Playlist Not Created",
            isPresented: Binding(
                get: { creationError != nil },
                set: { if !$0 { creationError = nil } })
        ) {
            Button("OK", role: .cancel) { creationError = nil }
        } message: {
            Text(creationError ?? "")
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard PlaylistStore.createPlaylist(named: name, in: modelContext) != nil else {
            creationError =
                "Atlas couldn’t create that playlist. The name may already exist or a storage limit was reached."
            return
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            PlaylistStore.delete(playlists[index], in: modelContext)
        }
    }
}

/// One playlist as a horizontal row, shared by the iPhone `List` and iPad grid.
private struct PlaylistRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let playlist: Playlist

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                PlaylistThumbnail(playlist: playlist)
                details
            }
        } else {
            HStack(spacing: 12) {
                PlaylistThumbnail(playlist: playlist)
                details
                Spacer(minLength: 0)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playlist.name)
                .font(.body.weight(.medium))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            Text("\(playlist.videos.count) video\(playlist.videos.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Small stacked-thumbnail preview of a playlist's first video.
private struct PlaylistThumbnail: View {
    let playlist: Playlist
    var body: some View {
        let first = playlist.orderedVideos.first
        Thumbnail(url: first?.thumbnailURL, networkScope: .selectedInstance)
            .aspectRatio(16 / 9, contentMode: .fill)
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
            .accessibilityHidden(true)
    }
}
