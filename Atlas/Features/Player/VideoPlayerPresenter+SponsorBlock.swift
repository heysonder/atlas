import AVKit
import CoreMedia
import PipedKit
import SwiftUI

extension VideoPlayerPresenter.Coordinator {
    // MARK: SponsorBlock
    //
    // We fetch crowdsourced skip segments after playback starts (so they never
    // delay the video), then watch the playhead with a fine-grained observer.
    // When it's inside an enabled segment, a "Skip …" button appears; tapping
    // it seeks to the segment's end. Nothing is skipped automatically.

    func loadSponsorSegments(
        for request: PlayRequest, player: AVPlayer, controller: AVPlayerViewController
    ) {
        let categories = app.activeSponsorCategoryIDs
        guard !categories.isEmpty else { return }
        guard let client = currentPipedClient else { return }
        let videoID = request.videoID
        Task { [weak self] in
            let fetched =
                (try? await client.sponsorSegments(
                    videoID: videoID, categories: categories)) ?? []
            let usable = await Task.detached(priority: .utility) {
                SponsorSegmentPolicy.usableSegments(fetched)
            }.value
            // Same-video re-present within the fetch window swaps players;
            // the identity check keeps observers off the old one.
            guard let self, self.presentedID == videoID, self.player === player else { return }
            guard !usable.isEmpty else { return }
            self.sponsorSegments = usable
            self.installSkipButton(on: controller)
            self.installSponsorTracking(on: player)
            PlaybackDiagnostics.message("sponsor-segments", videoID: videoID)
        }
    }

    private func installSponsorTracking(on player: AVPlayer) {
        if let sponsorObserver {
            player.removeTimeObserver(sponsorObserver)
            self.sponsorObserver = nil
        }
        sponsorObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                self?.updateSponsorPrompt(at: seconds)
            }
        }
    }

    private func updateSponsorPrompt(at seconds: Double) {
        guard seconds.isFinite else { return }
        let active = sponsorSegments.first { seconds >= $0.start && seconds < $0.end }
        if let active {
            let id = active.uuid ?? "\(active.start)-\(active.end)"
            guard sponsorModel.prompt?.id != id else { return }
            let end = active.end
            sponsorModel.onSkip = { [weak self] in self?.skipSponsor(to: end) }
            sponsorModel.prompt = .init(
                id: id, noun: active.sponsorCategory?.skipLabel ?? "segment")
        } else if sponsorModel.prompt != nil {
            sponsorModel.prompt = nil
        }
    }

    private func skipSponsor(to end: Double) {
        guard let player else { return }
        sponsorModel.prompt = nil
        player.seek(
            to: CMTime(seconds: end, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
    }

    /// Hosts the skip button. Unlike the Info button, this host fills the
    /// overlay's safe area and lets the SwiftUI view place the pill in the
    /// lower-trailing corner itself. A fixed full-size host means the pill
    /// never overflows its bounds as it animates in (a content-sized host
    /// collapses to zero between segments and momentarily draws the pill off
    /// the bottom of the screen). The empty area isn't hit-testable, and the
    /// host sits *below* the Info button, so neither the transport controls
    /// nor the Info button lose their taps.
    private func installSkipButton(on controller: AVPlayerViewController) {
        guard skipButtonHost == nil, let overlay = controller.contentOverlayView else { return }
        let host = UIHostingController(rootView: SkipSponsorButton(model: sponsorModel))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        controller.addChild(host)
        overlay.insertSubview(host.view, at: 0)
        host.didMove(toParent: controller)
        let guide = overlay.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: guide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
        skipButtonHost = host
    }

}
