import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class PlayerNowPlayingSession {
    private weak var player: AVPlayer?
    private var baseInfo: [String: Any] = [:]
    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkToken = UUID()

    func activate(
        player: AVPlayer,
        title: String,
        artist: String?,
        artworkURLString: String?
    ) {
        if self.player !== player {
            removePlayerObservers()
            self.player = player
            installPlayerObservers(on: player)
        }

        installRemoteCommandsIfNeeded()

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        baseInfo = info
        publish()
        loadArtwork(from: artworkURLString)
    }

    func refresh() {
        publish()
    }

    func deactivate(clear: Bool = true) {
        artworkTask?.cancel()
        artworkTask = nil
        artworkToken = UUID()
        removePlayerObservers()
        removeRemoteCommands()
        player = nil
        baseInfo = [:]
        if clear {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }

    private func installPlayerObservers(on player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 1),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publish()
            }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.publish()
            }
        }
    }

    private func removePlayerObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
    }

    private func publish() {
        guard let player, !baseInfo.isEmpty else { return }
        var info = baseInfo
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        let duration = player.currentItem?.duration.seconds
        if let duration, duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = player.timeControlStatus == .paused ? .paused : .playing
    }

    private func loadArtwork(from urlString: String?) {
        artworkTask?.cancel()
        artworkToken = UUID()
        let token = artworkToken
        guard let urlString, let url = URL(string: urlString) else { return }

        artworkTask = Task { [weak self] in
            let data: Data? = url.isFileURL
                ? try? Data(contentsOf: url)
                : (try? await URLSession.shared.data(from: url))?.0
            guard !Task.isCancelled,
                  let data,
                  let artwork = Self.makeArtwork(from: data) else { return }
            await MainActor.run {
                guard let self, self.artworkToken == token else { return }
                self.baseInfo[MPMediaItemPropertyArtwork] = artwork
                self.publish()
            }
        }
    }

    private nonisolated static func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        return MPMediaItemArtwork(boundsSize: size) { _ in
            UIImage(data: data) ?? UIImage()
        }
    }

    private func installRemoteCommandsIfNeeded() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()

        addTarget(center.playCommand) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.player?.play()
                self?.publish()
            }
            return .success
        }

        addTarget(center.pauseCommand) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.player?.pause()
                self?.publish()
            }
            return .success
        }

        addTarget(center.togglePlayPauseCommand) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                if player.timeControlStatus == .paused {
                    player.play()
                } else {
                    player.pause()
                }
                self.publish()
            }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        addTarget(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                self?.seek(to: event.positionTime)
            }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.isEnabled = true
        addTarget(center.skipForwardCommand) { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor [weak self] in
                self?.seek(by: interval)
            }
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.isEnabled = true
        addTarget(center.skipBackwardCommand) { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor [weak self] in
                self?.seek(by: -interval)
            }
            return .success
        }
    }

    private func addTarget(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        let target = command.addTarget(handler: handler)
        commandTargets.append((command, target))
    }

    private func removeRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        commandTargets.removeAll()
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    private func seek(by interval: TimeInterval) {
        guard let player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        seek(to: max(0, current + interval))
    }

    private func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publish()
            }
        }
    }
}
