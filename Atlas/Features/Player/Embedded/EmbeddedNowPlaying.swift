import AVFoundation
import MediaPlayer
import PipedKit
import UIKit

/// Lock-screen / Control Center "Now Playing" for the embedded player.
/// `AVPlayerViewController` does this for the full-screen player; the
/// embedded surface is a bare layer, so the info (title, channel, artwork,
/// position) and the remote commands (play, pause, skip, seek) are published
/// here explicitly through the shared info center and command center.
@MainActor
final class EmbeddedNowPlaying {
    private weak var player: AVPlayer?
    private weak var model: EmbeddedPlayerModel?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var artworkTask: Task<Void, Never>?
    private var info: [String: Any] = [:]
    private var isLive = false
    /// Only clear the center on detach if this player populated it.
    private var published = false

    func attach(to player: AVPlayer, model: EmbeddedPlayerModel) {
        detach()
        self.player = player
        self.model = model
        installCommands()
        observations.append(
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        observations.append(
            player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in self?.observeItem(player.currentItem) }
            })
    }

    /// Static fields for the current video; position fields come from `refresh`.
    func publish(title: String, artist: String?, artworkURL: String?, client: PolicyHTTPClient?, isLive: Bool) {
        self.isLive = isLive
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist ?? ""
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = isLive
        info[MPMediaItemPropertyArtwork] = nil
        published = true
        refresh()
        loadArtwork(artworkURL, client: client)
    }

    /// Elapsed, duration, and rate. Called on play/pause/seek and when the
    /// item becomes readable; the system interpolates in between.
    func refresh() {
        guard published, let player else { return }
        let current = player.currentTime().seconds
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = current.isFinite ? current : 0
        if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info[MPMediaItemPropertyPlaybackDuration] = nil
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.timeControlStatus == .paused ? 0 : Double(player.rate)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func detach() {
        artworkTask?.cancel()
        artworkTask = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        itemObservation?.invalidate()
        itemObservation = nil
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
        if published {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            published = false
        }
        info.removeAll()
        player = nil
        model = nil
    }

    // MARK: Internals

    private func observeItem(_ item: AVPlayerItem?) {
        itemObservation?.invalidate()
        itemObservation = item?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    private func loadArtwork(_ urlString: String?, client: PolicyHTTPClient?) {
        artworkTask?.cancel()
        guard let urlString, let url = URL(string: urlString) else { return }
        artworkTask = Task { [weak self] in
            let image = await Task.detached { () -> UIImage? in
                let data: Data?
                if url.isFileURL {
                    data = DownloadStore.contains(url) ? try? Data(contentsOf: url) : nil
                } else if let client {
                    data = (try? await client.data(from: url))?.0
                } else {
                    data = nil
                }
                guard let data else { return nil }
                return UIImage(data: data)
            }.value
            guard !Task.isCancelled, let image, let self else { return }
            // MediaPlayer calls this provider on its own queue; it must not
            // be main-actor isolated.
            nonisolated(unsafe) let provided = image
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in provided }
            self.info[MPMediaItemPropertyArtwork] = artwork
            self.refresh()
        }
    }

    private func installCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { [weak self] _ in
            self?.model?.player.play()
            return .success
        }
        add(center.pauseCommand) { [weak self] _ in
            self?.model?.player.pause()
            return .success
        }
        add(center.togglePlayPauseCommand) { [weak self] _ in
            self?.model?.togglePlayPause()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: EmbeddedPlayerModel.skipInterval)]
        add(center.skipForwardCommand) { [weak self] _ in
            self?.model?.skip(by: EmbeddedPlayerModel.skipInterval)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: EmbeddedPlayerModel.skipInterval)]
        add(center.skipBackwardCommand) { [weak self] _ in
            self?.model?.skip(by: -EmbeddedPlayerModel.skipInterval)
            return .success
        }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.model?.seek(toSeconds: event.positionTime)
            return .success
        }
    }

    /// MediaPlayer delivers remote command events on the main thread, the
    /// same assumption `PlayerFavoritesRemoteCommand` makes for the shared
    /// bookmark command.
    private func add(
        _ command: MPRemoteCommand,
        _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        commandTargets.append((command, command.addTarget(handler: handler)))
    }
}
