import PipedKit
import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \HistoryEntry.watchedAt, order: .reverse) private var history: [HistoryEntry]
    @State private var confirmingClear = false

    var body: some View {
        Group {
            if history.isEmpty {
                ContentUnavailableView(
                    "No history",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Videos you watch show up here."))
            } else if horizontalSizeClass == .regular {
                AdaptiveGrid {
                    ForEach(history) { entry in
                        Button {
                            app.nowPlaying = entry.asPlayRequest
                        } label: {
                            HistoryRow(entry: entry).libraryCard()
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            QueueMenuItems(request: entry.asPlayRequest)
                            Button(role: .destructive) {
                                PlaybackHistoryStore.remove([entry], in: modelContext)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            } else {
                List {
                    ForEach(history) { entry in
                        Button {
                            app.nowPlaying = entry.asPlayRequest
                        } label: {
                            HistoryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            QueueMenuItems(request: entry.asPlayRequest)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { confirmingClear = true }
                }
            }
        }
        .confirmationDialog(
            "Clear all watch history?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every saved watch and resume position from this device.")
        }
    }

    private func delete(_ offsets: IndexSet) {
        PlaybackHistoryStore.remove(offsets.map { history[$0] }, in: modelContext)
    }

    private func clearAll() {
        PlaybackHistoryStore.remove(history, in: modelContext)
    }
}

/// One history entry as a horizontal row, shared by the iPhone `List` and the
/// iPad card grid.
private struct HistoryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: HistoryEntry

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                LibraryVideoThumbnail(
                    url: entry.thumbnailURL,
                    networkScope: .selectedInstance)
                details
            }
        } else {
            HStack(spacing: 12) {
                LibraryVideoThumbnail(
                    url: entry.thumbnailURL,
                    networkScope: .selectedInstance)
                details
                Spacer(minLength: 0)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            if let uploader = entry.uploader {
                Text(uploader)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
        }
    }
}

extension HistoryEntry {
    fileprivate var asPlayRequest: PlayRequest {
        PlayRequest(videoID: videoID, title: title, uploader: uploader, thumbnail: thumbnailURL)
    }
}
