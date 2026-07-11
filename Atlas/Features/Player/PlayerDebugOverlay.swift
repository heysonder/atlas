import Foundation
import SwiftUI

struct PlayerDebugOverlay: View {
    let model: PlayerDebugModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                        .frame(width: 44, height: 44)
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
            row(
                "Item",
                Self.itemSummary(
                    status: model.itemStatus,
                    likelyToKeepUp: model.likelyToKeepUp,
                    bufferEmpty: model.bufferEmpty,
                    bufferFull: model.bufferFull))
            row("Pipeline", Self.pipelineLabel(model.pipeline))
            row("Res", Self.cleanValue(model.resolution, adaptive: "Auto", file: "File"))
            row("Codec", Self.cleanValue(model.codec, adaptive: "Auto", file: "File"))
            row("Variant", Self.variantSummary(rendition: model.rendition, bitrate: model.indicatedBitrate))
            row(
                "Network",
                "\(Self.formatMbps(model.observedBitrate, placeholder: "Measuring")) - \(model.stallCount) stalls")
            row("Data", ByteCountFormatter.string(fromByteCount: model.transferredBytes, countStyle: .file))
            row("Last Err", Self.cleanValue(model.error, none: "None"))
        }
        .font(.caption2.monospaced().weight(.medium))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: 360, alignment: .leading)
        .glassEffect(.regular.tint(.black.opacity(0.24)), in: .rect(cornerRadius: 22))
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .foregroundStyle(.white.opacity(0.68))
                Text(value)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(width: 62, alignment: .leading)
                Text(value)
            }
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
        let words =
            value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
        guard !words.isEmpty else { return "--" }
        return
            words
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
