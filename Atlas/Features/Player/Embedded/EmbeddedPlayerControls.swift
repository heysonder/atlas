import AVKit
import PipedKit
import SwiftUI

/// The custom transport overlay for the embedded player: tap to reveal,
/// auto-hides while playing. Double-tap either half of the video to skip;
/// press and hold anywhere to play at 2× until released.
struct EmbeddedPlayerControls: View {
    let model: EmbeddedPlayerModel
    let title: String
    let chapters: [VideoChapter]
    let isFullscreen: Bool
    let onDismiss: () -> Void
    let onToggleFullscreen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true
    /// Bumped on every interaction so the auto-hide timer restarts.
    @State private var hideToken = 0
    @State private var skipFlash: SkipFlash?
    @State private var holdingFastForward = false
    /// Buffering that has lasted long enough to be worth a spinner.
    @State private var showsBufferingSpinner = false
    /// Drive the rotate symbol effect on the skip glyphs (overlay and bar).
    @State private var backSkips = 0
    @State private var forwardSkips = 0
    @State private var lastTap: TapRecord?

    private var state: EmbeddedPlaybackState { model.playbackState }

    var body: some View {
        ZStack {
            tapLayer
            if visible {
                scrim
                    .transition(.opacity)
                chrome
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
            if let skipFlash {
                skipIndicator(skipFlash)
            }
            if holdingFastForward {
                fastForwardBadge
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: visible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: holdingFastForward)
        .task(id: hideToken) { await autoHide() }
        .onChange(of: state.isPlaying) { _, playing in
            if playing { hideToken += 1 } else { visible = true }
        }
        .onChange(of: state.isScrubbing) { _, scrubbing in
            if !scrubbing { hideToken += 1 }
        }
    }

    // MARK: Tap / double-tap

    private var tapLayer: some View {
        HStack(spacing: 0) {
            seekZone(forward: false)
            seekZone(forward: true)
        }
        .contentShape(Rectangle())
        .gesture(holdToFastForward)
        .simultaneousGesture(pinchToFill)
    }

    /// Full screen only: pinch out to crop the video to the screen, pinch in
    /// to letterbox it again, the way AVKit's double-tap zoom works.
    private var pinchToFill: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.05)
            .onEnded { value in
                guard isFullscreen else { return }
                if value.magnification > 1.1 {
                    model.chooseVideoFill(true)
                } else if value.magnification < 0.9 {
                    model.chooseVideoFill(false)
                }
            }
    }

    /// Press and hold: 2× while the finger stays down, normal speed on
    /// release. A long press followed by a drag keeps the hold alive, so the
    /// finger can wander without dropping the speed.
    private var holdToFastForward: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, _) = value, !holdingFastForward else { return }
                guard state.isPlaying else { return }
                holdingFastForward = true
                model.beginFastForward()
            }
            .onEnded { _ in
                guard holdingFastForward else { return }
                holdingFastForward = false
                model.endFastForward()
            }
    }

    private var fastForwardBadge: some View {
        VStack {
            HStack(spacing: 4) {
                Text("2×")
                    .font(.footnote.weight(.bold).monospacedDigit())
                Image(systemName: "forward.fill")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.top, isFullscreen ? 18 : 12)
            Spacer()
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityLabel("Playing at 2 times speed")
    }

    /// Single taps act immediately (no double-tap wait): the controls toggle
    /// on touch-up, and a second tap in the same zone within the window
    /// undoes that toggle and skips instead.
    private func seekZone(forward: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { handleTap(forward: forward) }
    }

    private func handleTap(forward: Bool) {
        let now = Date()
        if let last = lastTap, last.forward == forward,
            now.timeIntervalSince(last.time) < Self.doubleTapWindow
        {
            lastTap = nil
            visible = last.visibleBefore
            skip(forward: forward)
            flashSkip(forward: forward)
            return
        }
        lastTap = TapRecord(time: now, forward: forward, visibleBefore: visible)
        toggleVisible()
    }

    private static let doubleTapWindow: TimeInterval = 0.3

    private struct TapRecord {
        let time: Date
        let forward: Bool
        let visibleBefore: Bool
    }

    private func skip(forward: Bool) {
        model.skip(by: forward ? EmbeddedPlayerModel.skipInterval : -EmbeddedPlayerModel.skipInterval)
        if forward { forwardSkips += 1 } else { backSkips += 1 }
        hideToken += 1
    }

    private func flashSkip(forward: Bool) {
        let flash = SkipFlash(forward: forward, id: UUID())
        withAnimation(.easeOut(duration: 0.12)) { skipFlash = flash }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard skipFlash?.id == flash.id else { return }
            withAnimation(.easeIn(duration: 0.2)) { skipFlash = nil }
        }
    }

    /// The skip glyph, centred in the outer third of the video that was
    /// double-tapped, spun by the same rotate effect the bar buttons use.
    private func skipIndicator(_ flash: SkipFlash) -> some View {
        HStack(spacing: 0) {
            Color.clear.overlay {
                if !flash.forward { skipGlyph(forward: false, size: 34) }
            }
            Color.clear
            Color.clear.overlay {
                if flash.forward { skipGlyph(forward: true, size: 34) }
            }
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func skipGlyph(forward: Bool, size: CGFloat) -> some View {
        Image(systemName: forward ? "goforward.10" : "gobackward.10")
            .font(.system(size: size, weight: .medium))
            .symbolEffect(
                forward ? .rotate.clockwise.byLayer : .rotate.counterClockwise.byLayer,
                value: forward ? forwardSkips : backSkips
            )
            .controlShadow()
    }

    private func toggleVisible() {
        visible.toggle()
        hideToken += 1
    }

    private func autoHide() async {
        guard visible else { return }
        try? await Task.sleep(for: .seconds(3.5))
        guard !Task.isCancelled, state.isPlaying, !state.isScrubbing else { return }
        visible = false
    }

    // MARK: Controls

    /// A light, even dim with a touch more weight behind the bar; it reaches
    /// the screen edges only in full screen. Faded on its own and never
    /// scaled: the scale transition the chrome uses pulled this full-bleed
    /// layer in from the clip edge and flickered a border while animating.
    private var scrim: some View {
        ZStack {
            Color.black.opacity(0.22)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.55),
                    .init(color: .black.opacity(0.28), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea(edges: isFullscreen ? .all : [])
        .allowsHitTesting(false)
    }

    /// The bars and the centre cluster. Nothing here claims the empty space
    /// between buttons, so those taps reach `tapLayer` and toggle or skip
    /// exactly as they do with the controls hidden.
    private var chrome: some View {
        ZStack {
            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, isFullscreen ? 20 : 12)
            .padding(.vertical, isFullscreen ? 14 : 8)

            centerCluster
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            EmbeddedControlButton(isFullscreen ? "chevron.left" : "chevron.down", label: "Close") {
                if isFullscreen { onToggleFullscreen() } else { onDismiss() }
            }
            if isFullscreen {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 8)
            if !state.captionOptions.isEmpty {
                captionsMenu
            }
            if state.isPiPPossible {
                EmbeddedControlButton(
                    state.isPiPActive ? "pip.exit" : "pip.enter",
                    label: state.isPiPActive ? "Exit Picture in Picture" : "Picture in Picture"
                ) {
                    model.togglePictureInPicture()
                }
            }
        }
    }

    /// The item's subtitle tracks plus Off, as the native player's menu has.
    private var captionsMenu: some View {
        Menu {
            Picker("Subtitles", selection: captionSelection) {
                Text("Off").tag(Int?.none)
                ForEach(state.captionOptions) { option in
                    Text(option.title).tag(Optional(option.id))
                }
            }
        } label: {
            Image(systemName: state.selectedCaptionID == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 18, weight: .semibold))
                .controlShadow()
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Subtitles")
    }

    private var captionSelection: Binding<Int?> {
        Binding {
            state.selectedCaptionID
        } set: { id in
            model.selectCaption(state.captionOptions.first { $0.id == id })
            hideToken += 1
        }
    }

    private var centerCluster: some View {
        HStack(spacing: isFullscreen ? 56 : 40) {
            skipButton(forward: false)
            playPauseButton
            skipButton(forward: true)
        }
    }

    private func skipButton(forward: Bool) -> some View {
        Button {
            skip(forward: forward)
        } label: {
            skipGlyph(forward: forward, size: 26)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forward ? "Forward 10 seconds" : "Back 10 seconds")
    }

    private var playPauseButton: some View {
        Button {
            model.togglePlayPause()
            hideToken += 1
        } label: {
            ZStack {
                // Always mounted, so the glyph swap runs as a symbol replace
                // instead of a remove/insert fade.
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: isFullscreen ? 44 : 36, weight: .semibold))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .controlShadow()
                    .opacity(showsBufferingSpinner ? 0 : 1)
                if showsBufferingSpinner {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state.isPlaying)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsBufferingSpinner)
            .frame(width: 72, height: 72)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
        // Only a sustained wait shows the spinner. AVPlayer reports a brief
        // "waiting" on every play() while it evaluates buffering; swapping
        // the glyph for a spinner during that flash made resuming stutter.
        .task(id: state.isBuffering) {
            guard state.isBuffering else {
                showsBufferingSpinner = false
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            showsBufferingSpinner = true
        }
    }

    private var bottomBar: some View {
        EmbeddedTransportBar(
            model: model,
            chapters: chapters,
            isFullscreen: isFullscreen,
            onToggleFullscreen: onToggleFullscreen,
            onInteract: { hideToken += 1 })
    }

    private struct SkipFlash: Equatable {
        let forward: Bool
        let id: UUID
    }
}
