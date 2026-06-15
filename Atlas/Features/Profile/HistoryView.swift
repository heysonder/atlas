import SwiftUI
import SwiftData
import PipedKit

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \HistoryEntry.watchedAt, order: .reverse) private var history: [HistoryEntry]

    var body: some View {
        Group {
            if history.isEmpty {
                ContentUnavailableView("No history",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Videos you watch show up here."))
            } else {
                List {
                    ForEach(history) { entry in
                        Button { app.nowPlaying = entry.asPlayRequest } label: {
                            HStack(spacing: 12) {
                                Thumbnail(url: entry.thumbnailURL)
                                    .aspectRatio(16/9, contentMode: .fill)
                                    .frame(width: 120, height: 68)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                    if let uploader = entry.uploader {
                                        Text(uploader).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                app.playNext(entry.asPlayRequest)
                            }
                            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                                app.addToQueue(entry.asPlayRequest)
                            }
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
                    Button("Clear", role: .destructive) { clearAll() }
                }
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { context.delete(history[index]) }
    }

    private func clearAll() {
        for entry in history { context.delete(entry) }
    }
}

private extension HistoryEntry {
    var asPlayRequest: PlayRequest {
        PlayRequest(videoID: videoID, title: title, uploader: uploader, thumbnail: thumbnailURL)
    }
}
