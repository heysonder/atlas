import AVFoundation
import Observation
import PipedKit

@MainActor
@Observable
final class PlayerDebugModel {
    var isVisible = false
    var source = "unknown"
    var status = "unknown"
    var reason = "none"
    var rate: Float = 0
    var seconds: Double?
    var duration: Double?
    var bufferAhead: Double?
    var likelyToKeepUp = false
    var bufferEmpty = false
    var bufferFull = false
    var itemStatus = "unknown"
    var indicatedBitrate: Double?
    var observedBitrate: Double?
    var stallCount = 0
    var transferredBytes: Int64 = 0
    var rendition = "unknown"
    var pipeline = "unknown"
    var resolution = "unknown"
    var codec = "unknown"
    var error = "none"
    private var streamInfoByItag: [String: StreamDebugInfo] = [:]

    func reset() {
        source = "unknown"
        status = "unknown"
        reason = "none"
        rate = 0
        seconds = nil
        duration = nil
        bufferAhead = nil
        likelyToKeepUp = false
        bufferEmpty = false
        bufferFull = false
        itemStatus = "unknown"
        indicatedBitrate = nil
        observedBitrate = nil
        stallCount = 0
        transferredBytes = 0
        rendition = "unknown"
        pipeline = "unknown"
        resolution = "unknown"
        codec = "unknown"
        error = "none"
        streamInfoByItag = [:]
    }

    func configure(detail: VideoDetail, composed: Bool, allowAV1: Bool) {
        streamInfoByItag = PlayerDebugMetadata.buildStreamInfoByItag(detail.videoStreams ?? [])
        if composed {
            pipeline = "composed"
            if let source = detail.bestComposedSource(allowAV1: allowAV1),
                let info = PlayerDebugMetadata.info(for: source.video, in: streamInfoByItag)
            {
                apply(info)
                rendition = "video itag \(info.itag)"
            } else {
                resolution = "unknown"
                codec = "unknown"
                rendition = "composed"
            }
        } else if let hls = detail.hls, !hls.isEmpty {
            pipeline = "HLS"
            resolution = "adaptive"
            codec = "adaptive"
            rendition = "waiting"
        } else if let url = detail.playableURL,
            let info = PlayerDebugMetadata.info(for: url, in: streamInfoByItag)
        {
            pipeline = "progressive"
            apply(info)
            rendition = "video itag \(info.itag)"
        } else {
            pipeline = "direct"
            resolution = "unknown"
            codec = "unknown"
            rendition = "unknown"
        }
    }

    func configureLocal() {
        streamInfoByItag = [:]
        pipeline = "local"
        resolution = "file"
        codec = "file"
        rendition = "local"
    }

    func update(player: AVPlayer, source: String) {
        self.source = source
        status = PlayerDebugMetadata.timeControlStatusName(player.timeControlStatus)
        reason = PlayerDebugMetadata.waitingReasonName(player.reasonForWaitingToPlay)
        rate = player.rate
        seconds = Self.finite(player.currentTime().seconds)

        guard let item = player.currentItem else {
            duration = nil
            bufferAhead = nil
            itemStatus = "missing"
            likelyToKeepUp = false
            bufferEmpty = false
            bufferFull = false
            error = "missing item"
            return
        }

        duration = Self.finite(item.duration.seconds)
        itemStatus = PlayerDebugMetadata.itemStatusName(item.status)
        likelyToKeepUp = item.isPlaybackLikelyToKeepUp
        bufferEmpty = item.isPlaybackBufferEmpty
        bufferFull = item.isPlaybackBufferFull
        error = PlayerDebugMetadata.itemErrorSummary(item)
        updateBuffer(item: item, currentSeconds: seconds)
        updateAccessLog(item)
    }

    func updateAccessLog(_ item: AVPlayerItem?) {
        updatePresentationSize(item)
        guard let event = item?.accessLog()?.events.last else { return }
        indicatedBitrate = Self.positive(event.indicatedBitrate)
        observedBitrate = Self.positive(event.observedBitrate)
        stallCount = event.numberOfStalls
        transferredBytes = event.numberOfBytesTransferred
        let hlsItag = PlayerDebugMetadata.hlsItag(from: event.uri)
        let videoItag = PlayerDebugMetadata.videoItag(from: event.uri) ?? hlsItag
        if let videoItag, let info = streamInfoByItag[videoItag] {
            apply(info)
        }
        rendition = PlayerDebugMetadata.renditionLabel(
            hlsItag: hlsItag,
            videoItag: videoItag)
    }

    private func updateBuffer(item: AVPlayerItem, currentSeconds: Double?) {
        guard let currentSeconds else {
            bufferAhead = nil
            return
        }
        let bufferEnd = item.loadedTimeRanges
            .map(\.timeRangeValue)
            .map { $0.start.seconds + $0.duration.seconds }
            .filter(\.isFinite)
            .max()
        bufferAhead = bufferEnd.map { max(0, $0 - currentSeconds) }
    }

    private func updatePresentationSize(_ item: AVPlayerItem?) {
        guard let size = item?.presentationSize,
            size.width.isFinite,
            size.height.isFinite,
            size.width > 0,
            size.height > 0
        else {
            return
        }
        resolution = "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    private static func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    private static func positive(_ value: Double) -> Double? {
        value > 0 && value.isFinite ? value : nil
    }

    private func apply(_ info: StreamDebugInfo) {
        resolution = "\(info.width)x\(info.height)"
        codec = info.codecLabel
    }
}
