import SwiftUI

/// Softly lands an image that the reader had to wait for: it starts dim,
/// blurred and a hair low over a placeholder in its own average colour, then
/// sharpens into place.
///
/// The rule is about what was on screen, not where the bytes came from: a row
/// that rendered blank (even for one frame) reveals; a row whose image was
/// available synchronously from the memory cache shows it in its first frame
/// with no animation. Fast disk-cache loads therefore still reveal — a
/// prefetched thumbnail popping in at the bottom edge looked worse than the
/// animation — while scrolling back over rows already in memory never
/// flickers.
///
/// Usage: keep `revealed` true by default; when an image arrives for a blank
/// row set `revealed = false` before assigning it, and animate it back to true
/// from the image view's `onAppear` (the view has to exist at the dim state
/// first for the modifier values to animate).
struct ImageRevealModifier: ViewModifier {
    let revealed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0.15)
            // `opaque` skips the alpha-edge pass: thumbnails are opaque and
            // clipped, and it keeps the per-frame blur cheap enough for a
            // screenful of rows to animate at full frame rate.
            .blur(radius: revealed || reduceMotion ? 0 : 3.5, opaque: true)
            .offset(y: revealed || reduceMotion ? 0 : 2)
    }
}

extension View {
    func imageReveal(_ revealed: Bool) -> some View {
        modifier(ImageRevealModifier(revealed: revealed))
    }
}

extension Animation {
    static let imageReveal = Animation.easeOut(duration: 0.45)
}
