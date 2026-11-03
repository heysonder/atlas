import PipedKit
import SwiftUI

/// The bottom row of the embedded controls: elapsed, the scrubber (with
/// chapter divisions), remaining or LIVE, and the full-screen toggle. While
/// scrubbing, the chapter under the finger is named above the bar.
struct EmbeddedTransportBar: View {
    let model: EmbeddedPlayerModel
    let chapters: [VideoChapter]
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void
    /// Any tap here counts as activity for the controls' auto-hide timer.
    let onInteract: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: EmbeddedPlaybackState { model.playbackState }

    private var sortedChapters: [VideoChapter] {
        chapters.filter { $0.start >= 0 }.sorted { $0.start < $1.start }
    }

    /// Chapter boundaries as fractions of the timeline (VOD only).
    private var chapterMarkers: [Double] {
        guard state.hasDuration, !state.isLive else { return [] }
        return sortedChapters.dropFirst().map { Double($0.start) / state.duration }
    }

    /// The chapter the playhead (or the scrubbing finger) is in.
    private var currentChapter: VideoChapter? {
        guard state.hasDuration, !state.isLive else { return nil }
        let position = Int(state.position)
        return sortedChapters.last { $0.start <= position }
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.isScrubbing, let chapter = currentChapter, let name = chapter.title, !name.isEmpty {
                Text(name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .controlShadow()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                Text(Format.clock(Int(state.elapsed)))
                    .frame(minWidth: 36, alignment: .leading)

                // Live streams scrub across their DVR window; the badge
                // dims while behind the edge.
                EmbeddedScrubber(
                    progress: state.progress,
                    buffered: state.bufferedProgress,
                    markers: chapterMarkers,
                    isScrubbing: state.isScrubbing,
                    onBegin: { model.beginScrubbing() },
                    onChange: { fraction in
                        model.scrubPreview(toSeconds: state.seconds(forFraction: fraction))
                    },
                    onEnd: { fraction in
                        model.endScrubbing(atSeconds: state.seconds(forFraction: fraction))
                    }
                )
                .disabled(!state.hasTimeline)
                .opacity(state.hasTimeline ? 1 : 0.4)

                if state.isLive {
                    liveButton
                } else {
                    Text(remainingText)
                        .frame(minWidth: 40, alignment: .trailing)
                }
                EmbeddedControlButton(
                    isFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    label: isFullscreen ? "Exit full screen" : "Full screen",
                    size: 32, glyph: 16,
                    action: onToggleFullscreen)
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .controlShadow()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.isScrubbing)
    }

    /// Red while at the live edge; dimmed when behind it, and tapping jumps
    /// back to live.
    private var liveButton: some View {
        Button {
            model.seekToLiveEdge()
            onInteract()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(state.isAtLiveEdge ? Color(.systemRed) : .white.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text("LIVE")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(state.isAtLiveEdge ? .white : .white.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.isAtLiveEdge ? "Live" : "Go to live")
    }

    private var remainingText: String {
        guard state.hasDuration else { return "--:--" }
        return "−" + Format.clock(Int(state.remaining.rounded(.up)))
    }
}
