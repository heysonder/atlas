import AVFoundation

/// Subtitle selection for the embedded player. `AVPlayerViewController`
/// offers the item's legible tracks in its own menu; the bare layer has no
/// menu, so the tracks are read here and offered from the controls' top bar.
/// Captions start off (`PlayerCaptionSelection.keepOffByDefault`).
extension EmbeddedPlayerModel {
    func installCaptionTracking() {
        captionItemObservation?.invalidate()
        captionItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor [weak self] in self?.loadCaptionOptions(for: item) }
        }
    }

    func removeCaptionTracking() {
        captionItemObservation?.invalidate()
        captionItemObservation = nil
        captionLoadTask?.cancel()
        captionLoadTask = nil
        playbackState.captionOptions = []
        playbackState.selectedCaptionID = nil
    }

    func selectCaption(_ option: EmbeddedCaptionOption?) {
        guard let item = player.currentItem else { return }
        playbackState.selectedCaptionID = option?.id
        Task { @MainActor in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                player.currentItem === item
            else { return }
            item.select(option?.option, in: group)
        }
    }

    private func loadCaptionOptions(for item: AVPlayerItem?) {
        captionLoadTask?.cancel()
        playbackState.captionOptions = []
        playbackState.selectedCaptionID = nil
        guard let item else { return }
        captionLoadTask = Task { [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            guard let self, !Task.isCancelled, self.player.currentItem === item else { return }
            // Forced-only tracks render on their own and aren't a user choice.
            let options = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
            self.playbackState.captionOptions = options.enumerated().map { index, option in
                EmbeddedCaptionOption(id: index, option: option)
            }
        }
    }
}

/// One legible track, identified by its position in the item's group so two
/// tracks with the same display name stay distinct.
struct EmbeddedCaptionOption: Identifiable, Equatable {
    let id: Int
    let option: AVMediaSelectionOption

    var title: String { option.displayName }
}
