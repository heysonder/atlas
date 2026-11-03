import SwiftUI

/// The embedded player's "Skip …" pill, in the controls' own idiom: a small
/// white label on a translucent black capsule, like the 2× badge, rather than
/// the full-screen player's Liquid Glass button.
struct EmbeddedSkipSponsorButton: View {
    let model: SponsorSkipModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .trailing) {
            if let prompt = model.prompt {
                Button(action: model.onSkip) {
                    Label("Skip \(prompt.noun)", systemImage: "forward.end.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .transition(
                    reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: model.prompt)
    }
}
