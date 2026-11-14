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

    private static let minimumDistance: CGFloat = 12
    /// A release this fast downward dismisses however short the swipe was.
    private static let flickSpeed: CGFloat = 600
    /// A slow drag has to come this far…
    private static let dismissDistance: CGFloat = 110
    /// …or be heading this far when let go.
    private static let dismissProjection: CGFloat = 260
    /// Moving back up faster than this on release means "never mind".
    private static let cancelSpeed: CGFloat = -150
    /// How far past the release point a dismissed cover keeps sliding.
    private static let dismissTravel: CGFloat = 900

    func body(content: Content) -> some View {
        content.simultaneousGesture(drag)
    }

    private var drag: some Gesture {
        // Global space: the video this gesture sits on moves with the offset
        // it drives, so a local translation shrinks as the view follows the
        // finger and the cover shudders and pulls back up.
        DragGesture(minimumDistance: Self.minimumDistance, coordinateSpace: .global)
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
                let current = offset.wrappedValue
                let speed = value.velocity.height
                if shouldDismiss(value) {
                    // Keep travelling at the finger's speed while the cover
                    // dismisses, instead of stalling where it was released.
                    if !reduceMotion {
                        settle(to: current + Self.dismissTravel, from: current, speed: max(speed, 0))
                    }
                    onDismiss()
                } else if reduceMotion {
                    offset.wrappedValue = 0
                } else {
                    settle(to: 0, from: current, speed: speed)
                }
            }
    }

    /// The system's own rule for interactive dismissals: speed decides first,
    /// distance second. A hard flick dismisses even after a short travel, a
    /// slow drag needs real distance, and letting go while moving back up
    /// always cancels.
    private func shouldDismiss(_ value: DragGesture.Value) -> Bool {
        let speed = value.velocity.height
        if speed < Self.cancelSpeed { return false }
        if speed > Self.flickSpeed { return true }
        return value.translation.height > Self.dismissDistance
            || value.predictedEndTranslation.height > Self.dismissProjection
    }

    /// Springs the offset to `target`, starting at the speed the finger
    /// left with. A spring's initial velocity is a fraction of the distance
    /// to cover per second.
    private func settle(to target: CGFloat, from current: CGFloat, speed: CGFloat) {
        let distance = target - current
        let relative = abs(distance) > 1 ? speed / distance : 0
        let spring = Animation.interpolatingSpring(
            duration: 0.35, bounce: 0, initialVelocity: min(max(relative, -30), 30))
        withAnimation(spring) { offset.wrappedValue = target }
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
