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
        updatePresentationSize(item)
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

    private func updatePresentationSize(_ item: AVPlayerItem?) {
        guard let size = item?.presentationSize,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
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

    private static func itemErrorSummary(_ item: AVPlayerItem) -> String {
        if let event = item.errorLog()?.events.last {
            let media = errorMediaLabel(from: event.uri)
            if event.errorDomain == "CoreMediaErrorDomain", event.errorStatusCode == -12660 {
                return withMediaLabel("HTTP 403 Forbidden", media)
            }
            return withMediaLabel("\(event.errorStatusCode) \(event.errorDomain)", media)
        }
        return item.error?.localizedDescription ?? "none"
    }

    private static func withMediaLabel(_ base: String, _ media: String?) -> String {
        guard let media else { return base }
        return "\(base) - \(media)"
    }

    private static func errorMediaLabel(from uri: String?) -> String? {
        guard let uri else { return nil }
        let decoded = uri.removingPercentEncoding ?? uri
        if let label = playlistMediaLabel(in: decoded, kind: "video") {
            return label
        }
        if let label = playlistMediaLabel(in: decoded, kind: "audio") {
            return label
        }
        if let itag = videoItag(from: decoded) ?? hlsItag(from: decoded) {
            return "itag \(itag)"
        }
        return nil
    }

    private static func playlistMediaLabel(in uri: String, kind: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"/\#(kind)/(\d+)(?:[/?#]|$)"#) else {
            return nil
        }
        let range = NSRange(uri.startIndex..<uri.endIndex, in: uri)
        guard let match = expression.firstMatch(in: uri, range: range),
              match.numberOfRanges > 1,
              let mediaRange = Range(match.range(at: 1), in: uri) else {
            return nil
        }
        return "\(kind) \(String(uri[mediaRange]))"
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
        GlassEffectContainer(spacing: 12) {
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
                .glassEffect(.regular.tint(.black.opacity(0.12)).interactive(), in: Circle())
                .accessibilityLabel(model.isVisible ? "Hide player diagnostics" : "Show player diagnostics")

                if model.isVisible {
                    debugPanel
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Source", Self.sourceLabel(model.source))
            row("State", Self.playbackSummary(status: model.status, reason: model.reason, rate: model.rate))
            row("Wait", Self.waitReasonLabel(model.reason))
            row("Time", "\(Self.formatTime(model.seconds)) / \(Self.formatTime(model.duration))")
            row("Buffer", Self.formatSeconds(model.bufferAhead))
            row("Item", Self.itemSummary(
                status: model.itemStatus,
                likelyToKeepUp: model.likelyToKeepUp,
                bufferEmpty: model.bufferEmpty,
                bufferFull: model.bufferFull))
            row("Pipeline", Self.pipelineLabel(model.pipeline))
            row("Res", Self.cleanValue(model.resolution, adaptive: "Auto", file: "File"))
            row("Codec", Self.cleanValue(model.codec, adaptive: "Auto", file: "File"))
            row("Variant", Self.variantSummary(rendition: model.rendition, bitrate: model.indicatedBitrate))
            row("Network", "\(Self.formatMbps(model.observedBitrate, placeholder: "Measuring")) - \(model.stallCount) stalls")
            row("Data", ByteCountFormatter.string(fromByteCount: model.transferredBytes, countStyle: .file))
            row("Last Err", Self.cleanValue(model.error, none: "None"))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: 360, alignment: .leading)
        .glassEffect(.regular.tint(.black.opacity(0.24)), in: .rect(cornerRadius: 22))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.white.opacity(0.68))
                .frame(width: 62, alignment: .leading)
            Text(value)
        }
    }

    private static func sourceLabel(_ source: String) -> String {
        switch source {
        case "direct-av1-hls": "AV1 HLS"
        case "direct-initial": "Direct"
        case "fallback-direct": "Direct fallback"
        case "fallback-hls": "HLS fallback"
        case "fallback-composed": "Composed fallback"
        case "composed-initial": "Composed"
        case "local": "Local"
        case "unknown": "Pending"
        default: cleanToken(source)
        }
    }

    private static func playbackSummary(status: String, reason: String, rate: Float) -> String {
        switch status {
        case "playing": "Playing at \(formatRate(rate))x"
        case "paused": "Paused"
        case "waiting": waitReasonLabel(reason)
        case "unknown": "Starting"
        default: cleanToken(status)
        }
    }

    private static func waitReasonLabel(_ reason: String) -> String {
        switch reason {
        case "none": "Ready"
        case "minimizeStalls": "Buffering"
        case "evaluatingBuffer": "Checking buffer"
        case "noItem": "No item"
        case "unknown": "Starting"
        default: cleanToken(reason)
        }
    }

    private static func itemSummary(
        status: String,
        likelyToKeepUp: Bool,
        bufferEmpty: Bool,
        bufferFull: Bool
    ) -> String {
        var parts = [itemStatusLabel(status)]
        if status == "ready" {
            parts.append(likelyToKeepUp ? "can keep up" : "warming up")
        }
        if bufferEmpty {
            parts.append("buffer empty")
        } else if bufferFull {
            parts.append("buffer full")
        }
        return parts.joined(separator: " - ")
    }

    private static func itemStatusLabel(_ status: String) -> String {
        switch status {
        case "ready": "Ready"
        case "failed": "Failed"
        case "missing": "No item"
        case "unknown": "Preparing"
        default: cleanToken(status)
        }
    }

    private static func pipelineLabel(_ pipeline: String) -> String {
        switch pipeline {
        case "HLS": "HLS"
        case "composed": "Composed"
        case "progressive": "Progressive"
        case "direct": "Direct"
        case "local": "Local"
        case "unknown": "Pending"
        default: cleanToken(pipeline)
        }
    }

    private static func variantSummary(rendition: String, bitrate: Double?) -> String {
        let label = renditionLabel(rendition)
        let speed = formatMbps(bitrate)
        if speed == "--" { return label }
        return "\(label) - \(speed)"
    }

    private static func renditionLabel(_ rendition: String) -> String {
        if rendition == "unknown" { return "Adaptive" }
        if rendition == "waiting" { return "Selecting" }
        if let video = rendition.wholeMatch(of: /video itag (\d+)/)?.1 {
            return "Video \(video)"
        }
        if let match = rendition.wholeMatch(of: /hls (\d+) \/ video (\d+)/) {
            return "HLS \(match.1) - Video \(match.2)"
        }
        if let itag = rendition.wholeMatch(of: /itag (\d+)/)?.1 {
            return "Itag \(itag)"
        }
        return cleanToken(rendition)
    }

    private static func cleanValue(
        _ value: String,
        none: String = "None",
        adaptive: String = "Auto",
        file: String = "File"
    ) -> String {
        switch value {
        case "unknown": "--"
        case "none": none
        case "adaptive": adaptive
        case "file": file
        default: value
        }
    }

    private static func cleanToken(_ value: String) -> String {
        let words = value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
        guard !words.isEmpty else { return "--" }
        return words
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + String(word.dropFirst())
            }
            .joined(separator: " ")
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
        return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
    }

    private static func formatMbps(_ bitsPerSecond: Double?, placeholder: String) -> String {
        guard let bitsPerSecond else { return placeholder }
        return formatMbps(bitsPerSecond)
    }

    private static func formatRate(_ rate: Float) -> String {
        String(format: "%.1f", rate)
    }
}
