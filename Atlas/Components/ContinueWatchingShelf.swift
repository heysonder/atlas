import SwiftUI

/// A horizontal shelf of partly watched videos with how far along each one
/// is. Leads the History screen (and so the Library's default detail on iPad).
struct ContinueWatchingShelf: View {
    let entries: [HistoryEntry]
    let onPlay: (HistoryEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue Watching")
                .font(.title3.weight(.bold))
                .padding(.horizontal)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(entries) { entry in
                        ContinueWatchingCard(entry: entry) { onPlay(entry) }
                    }
                }
                .padding(.horizontal)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .padding(.vertical, 8)
    }
}

private struct ContinueWatchingCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: HistoryEntry
    let onPlay: () -> Void

    private static let width: CGFloat = 220

    private var fraction: Double {
        guard entry.durationSeconds > 0 else { return 0 }
        return min(max(entry.positionSeconds / entry.durationSeconds, 0), 1)
    }

    private var remainingText: String {
        let remaining = max(Int(entry.durationSeconds - entry.positionSeconds), 0)
        let minutes = (remaining + 30) / 60
        return minutes < 1 ? "Less than a minute left" : "\(minutes) min left"
    }

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                Thumbnail(url: entry.thumbnailURL, networkScope: .selectedInstance)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(width: Self.width, height: Self.width * 9 / 16)
                    .overlay(alignment: .bottom) {
                        // Resume position, drawn in the thumbnail's bottom edge.
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.35))
                                Rectangle().fill(.tint).frame(width: proxy.size.width * fraction)
                            }
                        }
                        .frame(height: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .imageEdge(RoundedRectangle(cornerRadius: 12, style: .continuous), url: entry.thumbnailURL)
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(remainingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.title)
        .accessibilityValue(remainingText)
    }
}
