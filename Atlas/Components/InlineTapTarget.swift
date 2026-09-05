import SwiftUI

extension View {
    /// Gives an inline text control (a "Show more", "View all", reply toggle,
    /// channel-name link…) a ~44pt tap target without changing its layout:
    /// the hit shape is inset outward past the label's bounds. A
    /// `.frame(minHeight: 44)` would do the same for touch but pads every
    /// row the control sits in — the gap under comment footers and meta lines.
    func inlineTapTarget(slop: CGFloat = 12) -> some View {
        contentShape(Rectangle().inset(by: -slop))
    }
}
