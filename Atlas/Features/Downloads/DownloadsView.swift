import SwiftData
import SwiftUI

/// Offline library: in-flight downloads (with progress) on top, finished ones
/// below. Tapping a finished download plays it from disk; swipe to delete.
struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \DownloadedVideo.createdAt, order: .reverse) private var saved: [DownloadedVideo]

    private var inFlight: [DownloadManager.ActiveDownload] {
        downloads.active.values.sorted { $0.title < $1.title }
    }

    var body: some View {
        Group {
            if saved.isEmpty && inFlight.isEmpty {
                ContentUnavailableView(
                    "No downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Long-press any video and choose Download to save it for offline."))
            } else if horizontalSizeClass == .regular {
                gridLayout
            } else {
                List {
                    if !inFlight.isEmpty {
                        Section("Downloading") {
                            ForEach(inFlight) { item in
                                ActiveDownloadRow(
                                    item: item,
                                    onCancel: { downloads.cancel(item.id) },
                                    onDismiss: { downloads.dismissFailed(item.id) })
                            }
                        }
                    }
                    if !saved.isEmpty {
                        // The "Saved" header only earns its place when there's a
                        // "Downloading" section above to distinguish it from.
                        if inFlight.isEmpty {
                            Section { savedRows }
                        } else {
                            Section("Saved") { savedRows }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// iPad: in-flight downloads stay full-width (their progress bars want the
    /// room); finished downloads tile into the adaptive multi-column grid.
    private var gridLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !inFlight.isEmpty {
                    sectionHeader("Downloading")
                    ForEach(inFlight) { item in
                        ActiveDownloadRow(
                            item: item,
                            onCancel: { downloads.cancel(item.id) },
                            onDismiss: { downloads.dismissFailed(item.id) }
                        )
                        .libraryCard()
                    }
                }
                if !saved.isEmpty {
                    if !inFlight.isEmpty { sectionHeader("Saved") }
                    LazyVGrid(columns: LibraryGrid.columns(), spacing: LibraryGrid.spacing) {
                        ForEach(saved) { video in
                            Button {
                                app.playDownloaded(video)
                            } label: {
                                DownloadedVideoRow(video: video).libraryCard()
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                QueueMenuItems(request: playRequest(for: video))
                                Button(role: .destructive) {
                                    downloads.remove(video.videoID)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder private var savedRows: some View {
        ForEach(saved) { video in
            Button {
                app.playDownloaded(video)
            } label: {
                DownloadedVideoRow(video: video)
            }
            .buttonStyle(.plain)
            .contextMenu {
                QueueMenuItems(request: playRequest(for: video))
            }
        }
        .onDelete(perform: deleteSaved)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deleteSaved(_ offsets: IndexSet) {
        for index in offsets { downloads.remove(saved[index].videoID) }
    }

    private func playRequest(for video: DownloadedVideo) -> PlayRequest {
        PlayRequest(download: video)
    }
}

/// A finished download: poster, title, uploader, and quality · size meta.
private struct DownloadedVideoRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let video: DownloadedVideo

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                posterThumbnail
                details
            }
        } else {
            HStack(spacing: 12) {
                posterThumbnail
                details
            }
        }
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
            Text(metaLine).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var metaLine: String {
        Format.metaLine(
            video.qualityLabel,
            video.byteCount > 0
                ? ByteCountFormatter.string(
                    fromByteCount: video.byteCount, countStyle: .file) : nil)
    }

    private var posterThumbnail: some View {
        // thumbnailURL is a local file URL, so this resolves offline.
        LibraryVideoThumbnail(
            url: video.thumbnailURL?.absoluteString,
            durationSeconds: video.durationSeconds)
    }
}

/// A download in progress (or failed), with a progress bar and a trailing
/// cancel / dismiss control.
private struct ActiveDownloadRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: DownloadManager.ActiveDownload
    let onCancel: () -> Void
    let onDismiss: () -> Void

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    thumbnail
                    Spacer(minLength: 0)
                    trailingControl
                }
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                statusLine
            }
        } else {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    statusLine
                }
                Spacer(minLength: 0)
                trailingControl
            }
        }
    }

    private var thumbnail: some View {
        LibraryVideoThumbnail(
            url: item.thumbnail,
            networkScope: .selectedInstance)
    }

    @ViewBuilder private var statusLine: some View {
        switch item.state {
        case .preparing:
            Text("Preparing…").font(.caption).foregroundStyle(.secondary)
        case .downloading:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: item.fraction)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue("\(Int(item.fraction * 100)) percent")
                Text("\(Int(item.fraction * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        case .processing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Finishing…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var trailingControl: some View {
        if item.isFailed {
            Button("Dismiss", systemImage: "xmark.circle.fill", action: onDismiss)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        } else {
            Button("Cancel", systemImage: "stop.circle.fill", action: onCancel)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
    }
}
