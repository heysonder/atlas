import SwiftUI

/// A compact "Watched" marker overlaid on a thumbnail the user has already seen.
/// Used on surfaces that show the full catalog (e.g. a channel page), where —
/// unlike the Home feed — watched videos stay visible rather than being hidden.
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
            .background(.red, in: Capsule())
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
    }
}
