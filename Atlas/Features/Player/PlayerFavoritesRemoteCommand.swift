import Foundation
import MediaPlayer
import SwiftData

@MainActor
final class PlayerFavoritesRemoteCommand {
    static let shared = PlayerFavoritesRemoteCommand()

    private var target: Any?
    private var request: PlayRequest?
    private var modelContext: ModelContext?

    private init() {}

    func update(request: PlayRequest?, modelContext: ModelContext?) {
        installIfNeeded()
        self.request = request
        self.modelContext = modelContext
        syncCommandState()
    }

    private func installIfNeeded() {
        guard target == nil else { return }

        let command = MPRemoteCommandCenter.shared().bookmarkCommand
        command.isEnabled = true
        command.localizedTitle = "Save to Favorites"
        command.localizedShortTitle = "Favorite"
        target = command.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            return self.handle(event)
        }
    }

    private func handle(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let request, let modelContext else {
            syncCommandState()
            return .noActionableNowPlayingItem
        }

        let isNegative = (event as? MPFeedbackCommandEvent)?.isNegative ?? false
        if isNegative {
            PlaylistStore.removeFromFavorites(
                videoID: request.videoID,
                in: modelContext,
                save: true)
        } else {
            PlaylistStore.addToFavorites(
                PlaylistVideoSnapshot(request: request),
                in: modelContext,
                save: true)
        }
        syncCommandState()
        return .success
    }

    private func syncCommandState() {
        let command = MPRemoteCommandCenter.shared().bookmarkCommand
        guard let request, let modelContext else {
            command.isEnabled = false
            command.isActive = false
            return
        }

        command.isEnabled = true
        command.isActive = PlaylistStore.isFavorite(videoID: request.videoID, in: modelContext)
    }
}
