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

/// Liquid Glass chip laid over a thumbnail (duration, Watched). Defaults to a
/// capsule; pass a `ConcentricRectangle` when the chip sits in the corner of a
/// thumbnail that declares a `containerShape`, so its corner nests inside.
struct ThumbnailChip<Content: View, ChipShape: Shape>: View {
    var shape: ChipShape
    var compact = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(compact ? .system(size: 10, weight: .medium) : .caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 1 : 3)
            .foregroundStyle(.primary)
            .glassEffect(.regular, in: shape)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

extension ThumbnailChip where ChipShape == Capsule {
    init(@ViewBuilder content: () -> Content) {
        self.init(shape: Capsule(), content: content)
    }
}
