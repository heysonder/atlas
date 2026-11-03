import SwiftUI

/// Swipe-down-to-dismiss for the embedded cover, split in two so the drag
/// stays smooth: `EmbeddedDismissOffset` owns the live offset and applies it
/// to the whole cover, and `EmbeddedDismissDragGesture` sits on the video
/// and writes into it through the environment. Holding the offset in
/// `EmbeddedPlayerView` itself re-ran that entire body, player and watch page
/// included, on every finger movement, which is what made the swipe stutter.
struct EmbeddedDismissOffset: ViewModifier {
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .environment(\.embeddedDismissOffset, $offset)
    }
}

/// Attached to the video with `simultaneousGesture` so the controls keep
/// working. The direction is decided once, when the finger first passes the
/// threshold: a predominantly vertical, downward start tracks the finger for
/// the rest of the drag (a sideways wobble mid-swipe no longer freezes the
/// view), anything else is ignored until the finger lifts. Never while the
/// scrubber is being dragged.
struct EmbeddedDismissDragGesture: ViewModifier {
    /// Off in full screen, where the chevron leaves full screen instead.
    let enabled: Bool
    let model: EmbeddedPlayerModel
    let onDismiss: () -> Void

    @Environment(\.embeddedDismissOffset) private var offset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tracking = false
    @State private var rejected = false

    private static let minimumDistance: CGFloat = 20
    private static let dismissDistance: CGFloat = 140
    private static let dismissProjection: CGFloat = 320

    func body(content: Content) -> some View {
        content.simultaneousGesture(drag)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: Self.minimumDistance)
            .onChanged { value in
                guard !rejected else { return }
                if !tracking {
                    let start = value.translation
                    guard enabled, !model.playbackState.isScrubbing, start.height > 0,
                        start.height > abs(start.width)
                    else {
                        rejected = true
                        return
                    }
                    tracking = true
                }
                // Measured from where tracking began, so the view starts
                // moving from rest instead of hopping by the threshold.
                offset.wrappedValue = max(value.translation.height - Self.minimumDistance, 0)
            }
            .onEnded { value in
                defer {
                    tracking = false
                    rejected = false
                }
                guard tracking else { return }
                if value.translation.height > Self.dismissDistance
                    || value.predictedEndTranslation.height > Self.dismissProjection
                {
                    onDismiss()
                } else if reduceMotion {
                    offset.wrappedValue = 0
                } else {
                    withAnimation(.spring(duration: 0.3)) { offset.wrappedValue = 0 }
                }
            }
    }
}

extension EnvironmentValues {
    /// The cover's live dismiss offset; written by the gesture on the video.
    @Entry var embeddedDismissOffset: Binding<CGFloat> = .constant(0)
}

extension View {
    func embeddedDismissOffset() -> some View {
        modifier(EmbeddedDismissOffset())
    }

    func embeddedDismissDrag(
        enabled: Bool, model: EmbeddedPlayerModel, onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(EmbeddedDismissDragGesture(enabled: enabled, model: model, onDismiss: onDismiss))
    }
}
