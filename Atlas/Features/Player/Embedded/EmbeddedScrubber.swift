import SwiftUI

/// The embedded player's seek bar: a thin track that thickens under the finger
/// and grows a knob while scrubbing, with a faint buffered band. Reports
/// fractions (0…1) so the caller maps them onto the item's duration.
struct EmbeddedScrubber: View {
    let progress: Double
    let buffered: Double
    /// Chapter boundaries (0…1) drawn as small gaps in the track.
    var markers: [Double] = []
    let isScrubbing: Bool
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    @State private var trackWidth: CGFloat = 0
    @State private var dragStartFraction: Double?

    private var trackHeight: CGFloat { isScrubbing ? 6 : 3 }
    /// The knob only appears under the finger, like the system scrubber.
    private var knobSize: CGFloat { isScrubbing ? 14 : 0 }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.25))
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: trackWidth * buffered)
            Capsule()
                .fill(.white)
                .frame(width: trackWidth * progress)
            ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .frame(width: 2, height: trackHeight)
                    .offset(x: trackWidth * marker - 1)
            }
        }
        .frame(height: trackHeight)
        .overlay(alignment: .leading) {
            Circle()
                .fill(.white)
                .frame(width: knobSize, height: knobSize)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .offset(x: trackWidth * progress - knobSize / 2)
                .opacity(isScrubbing ? 1 : 0)
        }
        .frame(height: 32)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            trackWidth = $0
        }
        .gesture(drag)
        .animation(.easeOut(duration: 0.15), value: isScrubbing)
        .sensoryFeedback(.selection, trigger: isScrubbing)
        .accessibilityElement()
        .accessibilityLabel("Seek")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.02
            let next = min(max(progress + (direction == .increment ? step : -step), 0), 1)
            onBegin()
            onEnd(next)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard trackWidth > 0 else { return }
                if dragStartFraction == nil {
                    dragStartFraction = progress
                    onBegin()
                }
                onChange(fraction(at: value.location.x))
            }
            .onEnded { value in
                dragStartFraction = nil
                guard trackWidth > 0 else { return }
                onEnd(fraction(at: value.location.x))
            }
    }

    private func fraction(at x: CGFloat) -> Double {
        min(max(Double(x / trackWidth), 0), 1)
    }
}
