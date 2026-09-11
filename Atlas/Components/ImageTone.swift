import SwiftUI
import UIKit

/// What the image pipeline learned about a picture's colours: its mean colour
/// (placeholder in the thumbnail's own tone) and what its border looks like
/// (whether a hairline is needed to keep its edge visible).
struct ImageTone: Equatable, Sendable {
    enum Edge: Sendable {
        /// Border is uniformly near-black: vanishes on a dark background.
        case dark
        /// Border is uniformly near-white: vanishes on a light background.
        case light
        /// Anything else — the picture draws its own edge.
        case mixed
    }

    let averageColor: UIColor?
    let edge: Edge
}

/// Per-URL memo of `ImageTone`, observable so a view that reads a tone before
/// the image has loaded re-renders when it arrives. Kept even after the image
/// itself leaves the memory cache; a few dozen bytes per URL.
@MainActor
@Observable
final class ImageToneStore {
    static let shared = ImageToneStore()

    private var tones: [String: ImageTone] = [:]
    private let limit = 6_000

    func tone(for url: String?) -> ImageTone? {
        url.flatMap { tones[$0] }
    }

    func set(_ tone: ImageTone, for url: String) {
        if tones.count >= limit { tones.removeAll(keepingCapacity: true) }
        tones[url] = tone
    }
}

/// A 0.5pt inner hairline in the image's clip shape, drawn only when the
/// picture's own border would otherwise melt into the surface: a near-black
/// edge in dark mode, a near-white edge in light mode. Busy edges get nothing.
struct ImageEdgeModifier<EdgeShape: InsettableShape>: ViewModifier {
    let shape: EdgeShape
    let url: String?
    @Environment(\.colorScheme) private var colorScheme

    private var needsEdge: Bool {
        switch ImageToneStore.shared.tone(for: url)?.edge {
        case .dark: colorScheme == .dark
        case .light: colorScheme == .light
        case .mixed, nil: false
        }
    }

    func body(content: Content) -> some View {
        content.overlay {
            if needsEdge {
                shape.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            }
        }
    }
}

extension View {
    /// See `ImageEdgeModifier`. Apply after the clip shape, with the same shape.
    func imageEdge(_ shape: some InsettableShape, url: String?) -> some View {
        modifier(ImageEdgeModifier(shape: shape, url: url))
    }
}
