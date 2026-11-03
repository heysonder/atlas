import PipedKit

/// SponsorBlock for the embedded player, mirroring the full-screen
/// coordinator: segments are fetched after playback starts so they never
/// delay the video, the progress tick checks the playhead against them, and a
/// "Skip …" pill appears while inside an enabled segment. Nothing is skipped
/// automatically.
extension EmbeddedPlayerModel {
    func loadSponsorSegments(client: PipedClient) {
        clearSponsorSegments()
        let categories = app.activeSponsorCategoryIDs
        guard !categories.isEmpty else { return }
        let videoID = request.videoID
        sponsorTask = Task { [weak self] in
            let fetched =
                (try? await client.sponsorSegments(videoID: videoID, categories: categories)) ?? []
            let usable = await Task.detached(priority: .utility) {
                SponsorSegmentPolicy.usableSegments(fetched)
            }.value
            // The video may have advanced while the fetch was out.
            guard let self, !Task.isCancelled, self.request.videoID == videoID, !usable.isEmpty else { return }
            self.sponsorSegments = usable
            PlaybackDiagnostics.message("sponsor-segments", videoID: videoID)
        }
    }

    /// Called from the half-second progress tick.
    func updateSponsorPrompt(at seconds: Double) {
        let active = sponsorSegments.first { seconds >= $0.start && seconds < $0.end }
        if let active {
            let id = active.uuid ?? "\(active.start)-\(active.end)"
            guard sponsorModel.prompt?.id != id else { return }
            let end = active.end
            sponsorModel.onSkip = { [weak self] in self?.skipSponsor(to: end) }
            sponsorModel.prompt = .init(id: id, noun: active.sponsorCategory?.skipLabel ?? "segment")
        } else if sponsorModel.prompt != nil {
            sponsorModel.prompt = nil
        }
    }

    func clearSponsorSegments() {
        sponsorTask?.cancel()
        sponsorTask = nil
        sponsorSegments = []
        sponsorModel.prompt = nil
    }

    /// Jumps past the segment without changing the play/pause state.
    private func skipSponsor(to end: Double) {
        sponsorModel.prompt = nil
        seek(toSeconds: end)
    }
}
