import SwiftUI
import PipedKit

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
        let noun: String   // e.g. "Sponsor", "Self-promo"
    }

    var prompt: Prompt?
    /// Seeks past the active segment. Replaced whenever `prompt` changes.
    @ObservationIgnored var onSkip: () -> Void = {}
}

/// The Liquid Glass "Skip …" pill layered over the video, pinned to the
/// lower-trailing corner above the transport bar. The view fills its host (the
/// player's safe area) and positions the pill itself with padding, so only the
/// pill is hit-testable — the empty space lets taps fall through to the controls
/// beneath. Filling a *stable* container, rather than letting the host resize to
/// the pill, is what keeps the show animation from briefly drawing the pill
/// off the bottom of the screen as the segment becomes active.
struct SkipSponsorButton: View {
    let model: SponsorSkipModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let prompt = model.prompt {
                Button(action: model.onSkip) {
                    Label("Skip \(prompt.noun)", systemImage: "forward.end.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .padding(.trailing, 12)
                .padding(.bottom, 56)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.prompt)
    }
}
