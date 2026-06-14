import SwiftUI

/// A compact "Watched" marker overlaid on a thumbnail the user has already seen.
/// Used on surfaces that show the full catalog (e.g. a channel page), where —
/// unlike the Home feed — watched videos stay visible rather than being hidden.
struct WatchedBadge: View {
    var body: some View {
        Label("Watched", systemImage: "checkmark.circle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .glassEffect(.regular, in: Capsule())
            .accessibilityLabel("Watched")
    }
}
