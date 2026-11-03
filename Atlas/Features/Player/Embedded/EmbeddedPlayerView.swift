import SwiftData
import SwiftUI

/// The "Embedded" player (opt-in via Settings): a custom-controlled video
/// surface pinned to the top with the watch page — title, channel, comments
/// card, related videos — scrolling beneath it. The native full-screen player
/// (`VideoPlayerPresenter`) is untouched and remains the default.
struct EmbeddedPlayerView: View {
    @State private var model: EmbeddedPlayerModel
    /// Live offset of the swipe-down-to-dismiss drag on the video area.
    @State private var dragOffset: CGFloat = 0
    /// Set by the full-screen button; rotating to landscape also fills the
    /// screen without this (see `isFullscreen`).
    @State private var fullscreenRequested = false
    /// Measured window shape: the inline layout must never be laid out in a
    /// wide window (mid-rotation, or when a portrait request is still
    /// settling), so a landscape-shaped container counts as full screen too.
    @State private var containerSize: CGSize = .zero
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(request: PlayRequest, app: AppModel, modelContext: ModelContext) {
        // Returning from PiP: the model that kept playing in the PiP window
        // is adopted as-is, so playback carries on instead of reloading.
        if let live = EmbeddedPlayerModel.pipRetainer, live.request.videoID == request.videoID {
            _model = State(initialValue: live)
        } else {
            _model = State(
                initialValue: EmbeddedPlayerModel(
                    request: request, app: app, modelContext: modelContext))
        }
    }

    private var isFullscreen: Bool {
        fullscreenRequested || verticalSizeClass == .compact
            || (containerSize.width > containerSize.height && containerSize.height > 0)
    }

    /// The feed's card geometry, for the "Rounded Corners" option.
    private static let cardCornerRadius: CGFloat = 14
    private static let cardInset: CGFloat = 16

    private var title: String {
        model.detail?.title ?? model.request.title
    }

    /// The decoded video's own shape once the item reports it; Piped's
    /// stream dimensions stand in until then. Portrait videos are capped at
    /// a square so the page beneath stays reachable.
    private var inlineAspectRatio: Double {
        let size = model.playbackState.videoSize
        let ratio =
            size.width > 0 && size.height > 0
            ? size.width / size.height
            : model.detail?.aspectRatio ?? 16.0 / 9.0
        return max(ratio, 1)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isFullscreen {
                    fullscreenLayout
                } else {
                    inlineLayout
                }
            }
            // No navigation bar on the root: the video pins to the top of the
            // safe area instead of sitting under a mostly-empty bar. Pushed
            // destinations (channel pages) still get their own bar.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                ChannelDetailView(channelID: id)
            }
        }
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            containerSize = $0
        }
        .offset(y: dragOffset)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: isFullscreen)
        .task {
            // The app is showing the player again, so a PiP window has no
            // reason to stay up: the same video folds back inline, and a
            // different video ends the old one's PiP (and its playback).
            if let other = EmbeddedPlayerModel.pipRetainer, other !== model {
                other.pipController?.stopPictureInPicture()
            }
            model.cancelDeferredTeardown()
            if model.playbackState.isPiPActive {
                model.pipController?.stopPictureInPicture()
            }
            model.start()
        }
        .onChange(of: verticalSizeClass) { old, new in
            // Rotating back to portrait leaves full screen, like the system
            // player; the button state would otherwise pin it there.
            if old == .compact, new == .regular { fullscreenRequested = false }
        }
        // Fill vs. letterbox is decided from the window's and the video's
        // shapes, both of which can arrive after full screen begins.
        .onChange(of: isFullscreen) { _, _ in refreshFullscreenFill() }
        .onChange(of: containerSize) { _, _ in refreshFullscreenFill() }
        .onChange(of: model.playbackState.videoSize) { _, _ in refreshFullscreenFill() }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // Once the phone is physically upright again the portrait lock
            // from "exit full screen" has done its job; let it rotate freely.
            if UIDevice.current.orientation.isPortrait, InterfaceOrientationLock.shared.mask == .portrait {
                InterfaceOrientationLock.shared.unlock()
            }
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            InterfaceOrientationLock.shared.unlock()
            // Keeps the player alive while PiP is running (mirrors the
            // fullscreen presenter's `pipActive` guard); teardown happens
            // when PiP ends instead.
            model.viewDisappeared()
        }
    }

    // MARK: Layouts

    private var inlineLayout: some View {
        let rounded = app.embeddedRoundedCorners
        let shape = RoundedRectangle(cornerRadius: rounded ? Self.cardCornerRadius : 0, style: .continuous)
        return VStack(spacing: 0) {
            videoArea(fillsScreen: false)
                .aspectRatio(inlineAspectRatio, contentMode: .fit)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: inlineAspectRatio)
                .frame(maxWidth: .infinity)
                .clipShape(shape)
                // Wins the height negotiation against the scroll view below,
                // so the video doesn't resize as the page's content changes.
                .layoutPriority(1)
                .simultaneousGesture(dismissDrag)
                // Same lift as the feed's thumbnail cards. The shadow sits on
                // a background shape: the video itself is a UIKit layer, which
                // SwiftUI's shadow can't trace.
                .background {
                    // Page-coloured so nothing shows at the corners; only
                    // the shadows it casts are visible: the card's crisp one
                    // plus a wider, very faint blur beneath the video.
                    shape
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.16), radius: 5, x: 0, y: 2)
                        .shadow(color: .black.opacity(0.07), radius: 18, x: 0, y: 8)
                }
                .padding(.horizontal, rounded ? Self.cardInset : 0)
                .padding(.top, rounded ? 8 : 0)
                .zIndex(1)
            infoArea
        }
    }

    private var fullscreenLayout: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            videoArea(fillsScreen: true)
        }
    }

    // MARK: Video

    /// The player surface plus everything layered over it: poster while the
    /// stream resolves, the custom controls, and the stats overlay.
    private func videoArea(fillsScreen: Bool) -> some View {
        ZStack {
            EmbeddedPlayerSurface(
                layerView: model.layerView,
                onPiPController: { [model] in model.adoptPiPController($0) }
            )
            .ignoresSafeArea(edges: fillsScreen ? .all : [])

            if !model.isReady {
                loadingPoster
            } else {
                EmbeddedPlayerControls(
                    model: model,
                    title: title,
                    chapters: model.detail?.chapters ?? [],
                    isFullscreen: isFullscreen,
                    onDismiss: closePlayer,
                    onToggleFullscreen: toggleFullscreen)
                // SponsorBlock's Skip pill, above the transport bar's trailing
                // end; it stays up whether or not the controls are showing.
                SkipSponsorButton(model: model.sponsorModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, fillsScreen ? 20 : 12)
                    .padding(.bottom, fillsScreen ? 64 : 52)
            }

            if app.statsForNerdsEnabled {
                PlayerDebugOverlay(model: model.debugModel)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.black)
    }

    /// Thumbnail + spinner until the item is attached, with a way out if the
    /// stream resolution is slow or fails.
    private var loadingPoster: some View {
        ZStack {
            Thumbnail(url: model.request.thumbnail, networkScope: .selectedInstance)
                .opacity(0.6)
            if model.errorMessage == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .accessibilityLabel("Loading video")
            }
        }
        .overlay(alignment: .topLeading) {
            EmbeddedControlButton(isFullscreen ? "chevron.left" : "chevron.down", label: "Close") {
                if isFullscreen { toggleFullscreen() } else { closePlayer() }
            }
            .foregroundStyle(.white)
            .padding(isFullscreen ? 20 : 12)
        }
    }

    /// Swipe down or the chevron. A playing video carries on in Picture in
    /// Picture over the screen the player was opened from, and PiP's return
    /// button re-presents this player (see `restoreInterfaceFromPiP`); a
    /// paused video simply closes.
    private func closePlayer() {
        model.handOffToPictureInPicture()
        dismiss()
    }

    private func refreshFullscreenFill() {
        if isFullscreen {
            model.applyFullscreenFill(containerSize: containerSize)
        } else {
            model.setVideoFillsScreen(false)
        }
    }

    /// iPhone only: iPad keeps its current orientation (multitasking ignores
    /// geometry requests anyway) and simply fills the window.
    private func toggleFullscreen() {
        let entering = !isFullscreen
        fullscreenRequested = entering
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let lock = InterfaceOrientationLock.shared
        if entering {
            lock.unlock(rotatingTo: .landscape)
        } else if verticalSizeClass == .compact {
            // Leaving full screen while the phone is held sideways: hold
            // portrait until the phone is upright, or the system flips the
            // interface straight back to landscape and the inline layout
            // ends up inside a landscape window.
            lock.lock(.portrait)
        } else {
            lock.unlock(rotatingTo: .portrait)
        }
    }

    /// Drag the video down to dismiss the player, YouTube-style. Attached with
    /// `simultaneousGesture` and a 20pt threshold so the controls keep working;
    /// only predominantly vertical drags move the view, and never while the
    /// scrubber is being dragged.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !model.playbackState.isScrubbing else { return }
                let dy = value.translation.height
                guard dy > 0, dy > abs(value.translation.width) else { return }
                dragOffset = dy
            }
            .onEnded { value in
                guard dragOffset > 0 else { return }
                if value.translation.height > 140
                    || value.predictedEndTranslation.height > 320
                {
                    closePlayer()
                } else if reduceMotion {
                    dragOffset = 0
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                }
            }
    }

    // MARK: Info

    @ViewBuilder private var infoArea: some View {
        if let detail = model.detail {
            if let client = model.client {
                EmbeddedWatchPage(model: model, detail: detail, client: client)
            } else {
                MissingInstanceView()
                    .padding()
            }
        } else if let message = model.errorMessage {
            Spacer()
            ErrorState(message: message) { model.retry() }
            Spacer()
        } else if model.request.localURL != nil {
            ScrollView { offlineInfo.padding() }
        } else {
            // Stream still resolving — the spinner sits over the video above.
            Spacer()
        }
    }

    /// Minimal info for offline playback, where no stream details (and thus no
    /// description or comments) are fetched.
    private var offlineInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.request.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let uploader = model.request.uploader, !uploader.isEmpty {
                Text(uploader)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Saved for offline — description and comments aren’t available.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
