import SwiftUI

/// Landscape container for the player's Info and Chat pages: a Liquid Glass
/// card docked to the trailing edge over the still-playing video, shaped like
/// a system sheet (inset 8pt from the horizontal safe area and from the
/// physical top and bottom edges, corners concentric with the display).
/// Plain regular glass, no tint — the user wants it to read as glass.
/// Tapping the video beside it closes it; the content gets a `close` action
/// for its Done button so the card animates out before the presentation is
/// dismissed. `onWillClose` fires as that animation starts.
///
/// Hand-rolled because no public sheet mode docks to the side in compact
/// height on iOS 27 (see `PlayerInfoSheet.asSideCard`).
struct PlayerSideCard<Content: View>: View {
    var width: CGFloat = 440
    var closeLabel: LocalizedStringKey = "Close"
    /// The window's bottom safe-area inset, captured by the presenter when it
    /// presents the card. The hosting controller hands SwiftUI no safe area of
    /// its own (`safeAreaRegions = []`), so the card's frame is fixed from the
    /// first layout instead of re-laying out when the presented view learns
    /// its insets a beat after appearing — which read as the card "growing"
    /// to the bottom half a second in. Horizontally the card and its content
    /// run to 8pt off the physical edge in both rotations.
    var bottomSafeInset: CGFloat = 0
    var onWillClose: () -> Void = {}
    var onDisappear: () -> Void = {}
    @ViewBuilder let content: (_ close: @escaping () -> Void) -> Content

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private let inset: CGFloat = 8
    private let cornerRadius: CGFloat = 26
    /// The Done capsule sits 22pt from the top and 22pt from the trailing edge
    /// of the card: the compact-height system bar alone puts it about 31pt
    /// down and 16pt in, so the bar is pulled up by 9pt and the content is
    /// inset 6pt per side (symmetric, so the title stays centred and the text
    /// margins match). Measured on device, not derived from an API.
    private let barTopTrim: CGFloat = 9
    private let contentSideInset: CGFloat = 6

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityLabel(closeLabel)
                .accessibilityAddTraits(.isButton)
            if shown {
                // Fade + a touch of scale rather than a slide: moving a large
                // glass surface (and a shadow) across live video re-renders
                // both every frame and stuttered on iPhone.
                card.transition(
                    reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { shown = true } }
        .onDisappear(perform: onDisappear)
    }

    private var card: some View {
        let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(cornerRadius)))
        return content(close)
            .padding(.top, -barTopTrim)
            .padding(.horizontal, contentSideInset)
            // The card runs to 8pt off the physical bottom and trailing edges
            // like a sheet; the content inside still steps clear of the home
            // indicator.
            .safeAreaPadding(.bottom, max(bottomSafeInset - inset, 0))
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
            .padding(inset)
    }

    private func close() {
        guard shown else { return }
        onWillClose()
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.2)) { dismiss() }
    }
}
