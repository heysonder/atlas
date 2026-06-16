import SwiftUI
import UniformTypeIdentifiers

struct PlayerInfoQueueSection: View {
    let onQueuedVideoPlay: (QueuedVideo) -> Void

    @Environment(AppModel.self) private var app
    @State private var draggedQueuedVideoID: UUID?

    private var queueItems: [QueueDisplayItem] {
        app.queuedVideos.enumerated().map {
            QueueDisplayItem(position: $0.offset, queued: $0.element)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Queue")
                    .font(.headline)
                if !queueItems.isEmpty {
                    Text("\(queueItems.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(queueItems) { item in
                    queueRow(item.queued, position: item.position)
                        .onDrag {
                            draggedQueuedVideoID = item.id
                            return NSItemProvider(object: item.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: QueueDropDelegate(
                                item: item,
                                draggedQueuedVideoID: $draggedQueuedVideoID,
                                app: app))
                }
            }
        }
    }

    private func queueRow(_ queued: QueuedVideo, position: Int) -> some View {
        Button {
            onQueuedVideoPlay(queued)
        } label: {
            HStack(spacing: 10) {
                queueThumbnail(queued, position: position)

                VStack(alignment: .leading, spacing: 3) {
                    Text(queued.request.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        if let uploader = queued.request.uploader, !uploader.isEmpty {
                            Text(uploader)
                                .lineLimit(1)
                        }
                        if queued.request.localURL != nil {
                            Label("Downloaded", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityLabel("Play \(queued.request.title)")
    }

    private func queueThumbnail(_ queued: QueuedVideo, position: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Thumbnail(url: queued.request.thumbnail)
                .aspectRatio(16 / 9, contentMode: .fill)
                .frame(width: 84, height: 47)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("\(position + 1)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(5)
        }
    }
}

private struct QueueDisplayItem: Identifiable {
    let position: Int
    let queued: QueuedVideo

    var id: UUID { queued.id }
}

private struct QueueDropDelegate: DropDelegate {
    let item: QueueDisplayItem
    @Binding var draggedQueuedVideoID: UUID?
    let app: AppModel

    func dropEntered(info: DropInfo) {
        guard let draggedQueuedVideoID,
              draggedQueuedVideoID != item.id,
              let source = app.queuedVideos.firstIndex(where: { $0.id == draggedQueuedVideoID }),
              let destination = app.queuedVideos.firstIndex(where: { $0.id == item.id })
        else { return }

        withAnimation(.snappy) {
            app.moveQueuedVideos(
                from: IndexSet(integer: source),
                to: destination > source ? destination + 1 : destination)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedQueuedVideoID = nil
        return true
    }
}
