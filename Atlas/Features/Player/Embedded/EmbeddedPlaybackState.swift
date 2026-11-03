import AVFoundation
import CoreMedia
import Observation

/// Fine-grained playback state for the custom embedded controls. Kept apart
/// from `EmbeddedPlayerModel` so the 10 Hz scrubber ticks only re-render the
/// control overlay, not the whole watch page beneath the video.
@MainActor
@Observable
final class EmbeddedPlaybackState {
    /// Current playhead in seconds (or the scrub preview while dragging).
    var position: Double = 0
    var duration: Double = 0
    /// End of the buffered range that contains the playhead.
    var bufferedEnd: Double = 0
    var isPlaying = false
    /// Waiting for data: shows the spinner over a frozen frame.
    var isBuffering = false
    /// Set from the stream detail as soon as it's known, and confirmed by an
    /// indefinite item duration once the item is readable.
    var isLive = false
    /// Live streams expose a DVR window rather than a duration: the scrubber
    /// spans `seekableStart…seekableEnd` and "LIVE" means sitting at the end.
    var seekableStart: Double = 0
    var seekableEnd: Double = 0
    var isScrubbing = false
    var hasItem = false
    var isPiPPossible = false
    var isPiPActive = false
    var videoSize: CGSize = .zero

    var hasDuration: Bool { duration.isFinite && duration > 0 }
    var hasSeekableWindow: Bool { seekableEnd - seekableStart > 1 }
    /// Within ~12s of the end of the seekable window counts as live: HLS
    /// targets a few segments behind the true edge.
    var isAtLiveEdge: Bool {
        guard isLive, hasSeekableWindow else { return isLive }
        return seekableEnd - position < 12
    }

    /// The scrubber's range: the full duration for VOD, the DVR window live.
    private var timelineStart: Double { isLive ? seekableStart : 0 }
    private var timelineEnd: Double { isLive ? seekableEnd : duration }
    private var timelineLength: Double { timelineEnd - timelineStart }
    var hasTimeline: Bool { isLive ? hasSeekableWindow : hasDuration }

    var progress: Double {
        guard hasTimeline, timelineLength > 0 else { return 0 }
        return min(max((position - timelineStart) / timelineLength, 0), 1)
    }
    var bufferedProgress: Double {
        guard hasTimeline, timelineLength > 0 else { return 0 }
        return min(max((bufferedEnd - timelineStart) / timelineLength, 0), 1)
    }
    /// Seconds into the timeline (what the left clock shows).
    var elapsed: Double { max(position - timelineStart, 0) }
    var remaining: Double { max(timelineEnd - position, 0) }

    func seconds(forFraction fraction: Double) -> Double {
        timelineStart + min(max(fraction, 0), 1) * timelineLength
    }

    @ObservationIgnored private var lastLoggedWindow: Double = -1
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observedPlayer: AVPlayer?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []

    func attach(to player: AVPlayer) {
        detach()
        observedPlayer = player
        // Delivered on the main queue, so no hop is needed; the KVO callbacks
        // below arrive on AVFoundation's threads and do hop.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.position = seconds }
            }
        }
        observations.append(
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    self?.isPlaying = player.timeControlStatus != .paused
                    self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            })
        observations.append(
            player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    self?.observeItem(player.currentItem)
                }
            })
    }

    func detach() {
        if let timeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observedPlayer = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        hasItem = false
        isPlaying = false
        isBuffering = false
        position = 0
        duration = 0
        bufferedEnd = 0
        seekableStart = 0
        seekableEnd = 0
        videoSize = .zero
    }

    private func observeItem(_ item: AVPlayerItem?) {
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        hasItem = item != nil
        guard let item else {
            duration = 0
            bufferedEnd = 0
            seekableStart = 0
            seekableEnd = 0
            position = 0
            videoSize = .zero
            return
        }
        itemObservations.append(
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    self?.updateDuration(item)
                }
            })
        itemObservations.append(
            item.observe(\.seekableTimeRanges, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    self?.updateSeekable(item)
                }
            })
        itemObservations.append(
            item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    self?.updateDuration(item)
                }
            })
        itemObservations.append(
            item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    self?.updateBuffered(item)
                }
            })
        itemObservations.append(
            item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    self?.videoSize = item.presentationSize
                }
            })
    }

    private func updateDuration(_ item: AVPlayerItem) {
        let seconds = item.duration.seconds
        if seconds.isFinite, seconds > 0 {
            duration = seconds
            isLive = false
        } else {
            duration = 0
            // An indefinite duration means a live/event stream once the item
            // is actually readable; before that the detail's flag stands.
            if item.status == .readyToPlay, item.duration.isIndefinite { isLive = true }
        }
    }

    private func updateSeekable(_ item: AVPlayerItem) {
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue)
            .filter { $0.start.isNumeric && $0.end.isNumeric }
        guard let first = ranges.first, let last = ranges.last else {
            seekableStart = 0
            seekableEnd = 0
            return
        }
        seekableStart = first.start.seconds
        seekableEnd = last.end.seconds
        // Window changes are logged sparingly: a live playlist refreshes
        // every few seconds, but only a materially different span matters.
        let length = seekableEnd - seekableStart
        if abs(length - lastLoggedWindow) > 60 || lastLoggedWindow < 0 {
            lastLoggedWindow = length
            PlaybackDiagnostics.message(
                "seekable-\(Int(seekableStart))-\(Int(seekableEnd))-live-\(isLive ? 1 : 0)")
        }
    }

    private func updateBuffered(_ item: AVPlayerItem) {
        let now = item.currentTime().seconds
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
        if let containing = ranges.first(where: {
            let start = $0.start.seconds
            let end = $0.end.seconds
            return now >= start - 0.5 && now <= end + 0.5
        }) {
            bufferedEnd = containing.end.seconds
        } else if let last = ranges.last {
            bufferedEnd = last.end.seconds
        } else {
            bufferedEnd = 0
        }
    }
}
