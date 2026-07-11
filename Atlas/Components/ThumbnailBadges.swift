import SwiftUI

/// A compact marker overlaid on thumbnails the user has already watched.
struct WatchedBadge: View {
    var body: some View {
        ThumbnailChip {
            Label("Watched", systemImage: "checkmark.circle.fill")
        }
        .accessibilityLabel("Watched")
    }
}

struct LiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(
                Color(.systemRed).mix(with: .black, by: 0.35),
                in: Capsule()
            )
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityLabel("Live")
    }
}

struct ThumbnailChip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(.primary)
            .glassEffect(.regular, in: Capsule())
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
