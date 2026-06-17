import AVFoundation
import PipedKit
import SwiftUI

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
        streamInfoByItag = Self.buildStreamInfoByItag(detail.videoStreams ?? [])
        if composed {
            pipeline = "composed"
            if let source = detail.bestComposedSource(allowAV1: allowAV1),
               let info = Self.info(for: source.video, in: streamInfoByItag) {
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
                  let info = Self.info(for: url, in: streamInfoByItag) {
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
        status = Self.timeControlStatusName(player.timeControlStatus)
        reason = Self.waitingReasonName(player.reasonForWaitingToPlay)
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
        itemStatus = Self.itemStatusName(item.status)
        likelyToKeepUp = item.isPlaybackLikelyToKeepUp
        bufferEmpty = item.isPlaybackBufferEmpty
        bufferFull = item.isPlaybackBufferFull
        error = Self.itemErrorSummary(item)
        updateBuffer(item: item, currentSeconds: seconds)
        updateAccessLog(item)
    }

    func updateAccessLog(_ item: AVPlayerItem?) {
        guard let event = item?.accessLog()?.events.last else { return }
        indicatedBitrate = Self.positive(event.indicatedBitrate)
        observedBitrate = Self.positive(event.observedBitrate)
        stallCount = event.numberOfStalls
        transferredBytes = event.numberOfBytesTransferred
        let hlsItag = Self.hlsItag(from: event.uri)
        let videoItag = Self.videoItag(from: event.uri) ?? hlsItag
        if let videoItag, let info = streamInfoByItag[videoItag] {
            apply(info)
        }
        rendition = Self.renditionLabel(hlsItag: hlsItag, videoItag: videoItag)
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

    private static func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    private static func positive(_ value: Double) -> Double? {
        value > 0 && value.isFinite ? value : nil
    }

    private static func itemErrorSummary(_ item: AVPlayerItem) -> String {
        if let event = item.errorLog()?.events.last {
            return "\(event.errorStatusCode) \(event.errorDomain)"
        }
        return item.error?.localizedDescription ?? "none"
    }

    private static func itemStatusName(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: "unknown"
        case .readyToPlay: "ready"
        case .failed: "failed"
        @unknown default: "unrecognized"
        }
    }

    private static func timeControlStatusName(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        case .playing: "playing"
        @unknown default: "unrecognized"
        }
    }

    private static func waitingReasonName(_ reason: AVPlayer.WaitingReason?) -> String {
        switch reason {
        case .toMinimizeStalls: "minimizeStalls"
        case .evaluatingBufferingRate: "evaluatingBuffer"
        case .noItemToPlay: "noItem"
        case nil: "none"
        default: reason?.rawValue ?? "unknown"
        }
    }

    private func apply(_ info: StreamDebugInfo) {
        resolution = "\(info.width)x\(info.height)"
        codec = info.codecLabel
    }

    private static func buildStreamInfoByItag(_ streams: [PipedKit.Stream]) -> [String: StreamDebugInfo] {
        streams.reduce(into: [:]) { result, stream in
            guard let rawURL = stream.url,
                  let itag = queryValue("itag", in: rawURL),
                  let width = stream.width,
                  let height = stream.height,
                  width > 0,
                  height > 0 else {
                return
            }
            result[itag] = StreamDebugInfo(
                itag: itag,
                width: width,
                height: height,
                codec: stream.codec,
                quality: stream.quality)
        }
    }

    private static func info(for url: URL, in streamInfoByItag: [String: StreamDebugInfo]) -> StreamDebugInfo? {
        guard let itag = queryValue("itag", in: url.absoluteString) else { return nil }
        return streamInfoByItag[itag]
    }

    private static func hlsItag(from uri: String?) -> String? {
        guard let uri,
              let expression = try? NSRegularExpression(pattern: #"[/&?]itag[/=](\d+)"#) else {
            return nil
        }
        let range = NSRange(uri.startIndex..<uri.endIndex, in: uri)
        guard let match = expression.firstMatch(in: uri, range: range),
              match.numberOfRanges > 1,
              let itagRange = Range(match.range(at: 1), in: uri) else {
            return nil
        }
        return String(uri[itagRange])
    }

    private static func videoItag(from uri: String?) -> String? {
        guard let uri else { return nil }
        let decoded = uri.removingPercentEncoding ?? uri
        return queryValues("itag", in: decoded).last
    }

    private static func queryValue(_ name: String, in raw: String) -> String? {
        queryValues(name, in: raw).first
    }

    private static func queryValues(_ name: String, in raw: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"(?:(?:^|[?&;/])\#(name)[=/])(\d+)"#) else {
            return []
        }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = expression.matches(in: raw, range: range)
        return matches.compactMap { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: raw) else {
                return nil
            }
            return String(raw[valueRange])
        }
    }

    private static func renditionLabel(hlsItag: String?, videoItag: String?) -> String {
        switch (hlsItag, videoItag) {
        case let (hls?, video?) where hls != video:
            return "hls \(hls) / video \(video)"
        case let (hls?, _):
            return "itag \(hls)"
        case let (_, video?):
            return "video \(video)"
        default:
            return "unknown"
        }
    }
}

private struct StreamDebugInfo {
    let itag: String
    let width: Int
    let height: Int
    let codec: String?
    let quality: String?

    var codecLabel: String {
        let lower = (codec ?? "").lowercased()
        if lower.hasPrefix("avc1") { return "H.264" }
        if lower.hasPrefix("vp09") || lower.hasPrefix("vp9") { return "VP9" }
        if lower.hasPrefix("av01") { return "AV1" }
        return codec ?? "unknown"
    }
}

struct PlayerDebugOverlay: View {
    let model: PlayerDebugModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    model.isVisible.toggle()
                }
            } label: {
                Image(systemName: model.isVisible ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Player diagnostics")

            if model.isVisible {
                debugPanel
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("source", model.source)
            row("state", "\(model.status) @ \(Self.formatRate(model.rate))x")
            row("reason", model.reason)
            row("time", "\(Self.formatTime(model.seconds)) / \(Self.formatTime(model.duration))")
            row("buffer", Self.formatSeconds(model.bufferAhead))
            row("item", "\(model.itemStatus) keep=\(model.likelyToKeepUp ? "yes" : "no") empty=\(model.bufferEmpty ? "yes" : "no") full=\(model.bufferFull ? "yes" : "no")")
            row("pipeline", model.pipeline)
            row("res", model.resolution)
            row("codec", model.codec)
            row("variant", "\(model.rendition) \(Self.formatMbps(model.indicatedBitrate))")
            row("network", "obs \(Self.formatMbps(model.observedBitrate)) stalls \(model.stallCount)")
            row("bytes", ByteCountFormatter.string(fromByteCount: model.transferredBytes, countStyle: .file))
            row("error", model.error)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(10)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.white.opacity(0.64))
                .frame(width: 62, alignment: .leading)
            Text(value)
        }
    }

    private static func formatTime(_ seconds: Double?) -> String {
        guard let seconds else { return "--:--" }
        let wholeSeconds = max(0, Int(seconds.rounded()))
        return "\(wholeSeconds / 60):\(String(format: "%02d", wholeSeconds % 60))"
    }

    private static func formatSeconds(_ seconds: Double?) -> String {
        guard let seconds else { return "--" }
        return "\(Int(seconds.rounded()))s"
    }

    private static func formatMbps(_ bitsPerSecond: Double?) -> String {
        guard let bitsPerSecond else { return "--" }
        return String(format: "%.1fMbps", bitsPerSecond / 1_000_000)
    }

    private static func formatRate(_ rate: Float) -> String {
        String(format: "%.1f", rate)
    }
}
