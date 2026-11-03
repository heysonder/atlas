import SwiftUI

/// A bare glyph button for the controls over the embedded video. It inherits
/// the overlay's foreground colour; the shadow keeps it legible on bright
/// frames without glass or a circle behind it.
struct EmbeddedControlButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 40
    var glyph: CGFloat = 18
    let action: () -> Void

    init(_ symbol: String, label: String, size: CGFloat = 40, glyph: CGFloat = 18, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.size = size
        self.glyph = glyph
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .controlShadow()
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension View {
    /// Plain white glyphs over video need a touch of shadow to stay legible on
    /// bright frames.
    func controlShadow() -> some View {
        shadow(color: .black.opacity(0.45), radius: 3, y: 1)
    }
}
