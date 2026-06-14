import SwiftUI
import SwiftData

/// Offline library: in-flight downloads (with progress) on top, finished ones
/// below. Tapping a finished download plays it from disk; swipe to delete.
struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.modelContext) private var context
    @Query(sort: \DownloadedVideo.createdAt, order: .reverse) private var saved: [DownloadedVideo]

    private var inFlight: [DownloadManager.ActiveDownload] {
        downloads.active.values.sorted { $0.title < $1.title }
    }

    var body: some View {
        Group {
            if saved.isEmpty && inFlight.isEmpty {
                ContentUnavailableView("No downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Long-press any video and choose Download to save it for offline."))
            } else {
                List {
                    if !inFlight.isEmpty {
                        Section("Downloading") {
                            ForEach(inFlight) { item in
                                ActiveRow(item: item,
                                          onCancel: { downloads.cancel(item.id) },
                                          onDismiss: { downloads.dismissFailed(item.id) })
                            }
                        }
                    }
                    if !saved.isEmpty {
                        Section(inFlight.isEmpty ? "" : "Saved") {
                            ForEach(saved) { video in
                                Button { app.playDownloaded(video) } label: {
                                    SavedRow(video: video)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete(perform: deleteSaved)
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func deleteSaved(_ offsets: IndexSet) {
        for index in offsets { downloads.remove(saved[index].videoID) }
    }
}

/// A finished download: poster, title, uploader, and quality · size meta.
private struct SavedRow: View {
    let video: DownloadedVideo

    var body: some View {
        HStack(spacing: 12) {
            posterThumb
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if let uploader = video.uploader {
                    Text(uploader).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(metaLine).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var metaLine: String {
        Format.metaLine(video.qualityLabel,
                        video.byteCount > 0 ? ByteCountFormatter.string(
                            fromByteCount: video.byteCount, countStyle: .file) : nil)
    }

    private var posterThumb: some View {
        ZStack(alignment: .bottomTrailing) {
            // thumbnailURL is a local file:// URL, so this resolves offline.
            Thumbnail(url: video.thumbnailURL?.absoluteString)
                .aspectRatio(16/9, contentMode: .fill)
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            let d = Format.duration(video.durationSeconds)
            if !d.isEmpty {
                Text(d).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white).padding(5)
            }
        }
    }
}

/// A download in progress (or failed), with a progress bar and a trailing
/// cancel / dismiss control.
private struct ActiveRow: View {
    let item: DownloadManager.ActiveDownload
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.thumbnail)
                .aspectRatio(16/9, contentMode: .fill)
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                statusLine
            }
            Spacer(minLength: 0)
            trailingControl
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch item.state {
        case .preparing:
            Text("Preparing…").font(.caption).foregroundStyle(.secondary)
        case .downloading:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: item.fraction)
                Text("\(Int(item.fraction * 100))%").font(.caption2).foregroundStyle(.secondary)
            }
        case .processing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Finishing…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    @ViewBuilder private var trailingControl: some View {
        if item.isFailed {
            Button("Dismiss", systemImage: "xmark.circle.fill", action: onDismiss)
                .labelStyle(.iconOnly).foregroundStyle(.secondary)
        } else {
            Button("Cancel", systemImage: "stop.circle.fill", action: onCancel)
                .labelStyle(.iconOnly).foregroundStyle(.secondary)
        }
    }
}
