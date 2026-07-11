import SwiftData
import SwiftUI

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Bindable var playlist: Playlist

    var body: some View {
        Group {
            if playlist.videos.isEmpty {
                ContentUnavailableView(
                    "Empty playlist",
                    systemImage: "music.note.list",
                    description: Text(
                        "Long-press a video anywhere and choose Add to Playlist."))
            } else if horizontalSizeClass == .regular {
                AdaptiveGrid {
                    ForEach(playlist.orderedVideos) { video in
                        Button {
                            app.playPlaylistVideo(video)
                        } label: {
                            PlaylistVideoRow(video: video).libraryCard()
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            QueueMenuItems(request: playRequest(for: video))
                            Button(role: .destructive) {
                                PlaylistStore.removeVideoID(
                                    video.videoID,
                                    from: playlist,
                                    in: modelContext)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            } else {
                List {
                    ForEach(playlist.orderedVideos) { video in
                        Button {
                            app.playPlaylistVideo(video)
                        } label: {
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
        let orderedVideos = playlist.orderedVideos
        for index in offsets {
            PlaylistStore.removeVideoID(
                orderedVideos[index].videoID,
                from: playlist,
                in: modelContext)
        }
    }

    private func playRequest(for video: PlaylistVideo) -> PlayRequest {
        PlayRequest(
            videoID: video.videoID,
            title: video.title,
            uploader: video.uploader,
            thumbnail: video.thumbnailURL)
    }
}

/// One playlist video as a horizontal row, shared by the iPhone list and iPad grid.
private struct PlaylistVideoRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let video: PlaylistVideo

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail
                details
            }
        } else {
            HStack(spacing: 12) {
                thumbnail
                details
                Spacer(minLength: 0)
            }
        }
    }

    private var thumbnail: some View {
        LibraryVideoThumbnail(
            url: video.thumbnailURL,
            durationSeconds: video.duration,
            networkScope: .selectedInstance)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(video.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            if let uploader = video.uploader {
                Text(uploader)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
        }
    }
}
