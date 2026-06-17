import SwiftUI

/// Drives the in-player "Info" button. While the video plays the button shows
/// just the ⓘ glyph; when the coordinator sets `isPaused` it expands to reveal
/// the "Info" label, matching the more discoverable controls-visible state.
@MainActor
@Observable
final class InfoButtonModel {
    var isPaused = false
    @ObservationIgnored var onTap: () -> Void = {}
}

@MainActor
@Observable
final class PlayerPlaybackTime {
    var seconds: Double?
}

/// The small Liquid Glass "Info" button layered over the video.
struct InfoOverlayButton: View {
    let model: InfoButtonModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let expandedFootprintWidth: CGFloat = 88

    var body: some View {
        Button(action: model.onTap) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                if model.isPaused {
                    Text("Info")
                        .transition(.blurReplace)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, model.isPaused ? 14 : 10)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .frame(minWidth: expandedFootprintWidth, alignment: .trailing)
        .accessibilityLabel("Info")
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: model.isPaused)
    }
}
