import PipedKit
import SwiftUI

/// Drives the in-player "Skip …" button. The player coordinator sets `prompt`
/// when the playhead enters an enabled SponsorBlock segment and clears it when
/// it leaves; the button's tap calls `onSkip`.
@MainActor
@Observable
final class SponsorSkipModel {
    /// What the button currently offers. `id` is the segment UUID so the same
    /// prompt isn't re-created (and re-animated) every observer tick.
    struct Prompt: Equatable {
        let id: String
        let noun: String  // e.g. "Sponsor", "Self-promo"
    }

    var prompt: Prompt?
    /// Seeks past the active segment. Replaced whenever `prompt` changes.
    @ObservationIgnored var onSkip: () -> Void = {}
}

/// The Liquid Glass "Skip …" pill layered over the video, pinned to the
/// lower-trailing corner above the transport bar on the same trailing line as
/// the Info/Chat cluster. The host is sized to a stable reserved width (not
/// the pill), so the show animation never draws the pill outside its bounds
/// and only the pill itself is hit-testable.
struct SkipSponsorButton: View {
    let model: SponsorSkipModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .trailing) {
            if let prompt = model.prompt {
                Button(action: model.onSkip) {
                    Label("Skip \(prompt.noun)", systemImage: "forward.end.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, PlayerOverlayLayout.horizontalPadding)
                        .padding(.vertical, PlayerOverlayLayout.verticalPadding)
                        .frame(minHeight: PlayerOverlayLayout.buttonHeight)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .transition(
                    reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }
        }
        .frame(
            width: PlayerOverlayLayout.skipReservedWidth, height: PlayerOverlayLayout.buttonHeight,
            alignment: .trailing
        )
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: model.prompt)
    }
}
