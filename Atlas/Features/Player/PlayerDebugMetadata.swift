import AVFoundation
import Foundation
import PipedKit

enum PlayerDebugMetadata {
    static func itemErrorSummary(_ item: AVPlayerItem) -> String {
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
            let mediaRange = Range(match.range(at: 1), in: uri)
        else {
            return nil
        }
        return "\(kind) \(String(uri[mediaRange]))"
    }

    static func itemStatusName(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: "unknown"
        case .readyToPlay: "ready"
        case .failed: "failed"
        @unknown default: "unrecognized"
        }
    }

    static func timeControlStatusName(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        case .playing: "playing"
        @unknown default: "unrecognized"
        }
    }

    static func waitingReasonName(_ reason: AVPlayer.WaitingReason?) -> String {
        switch reason {
        case .toMinimizeStalls: "minimizeStalls"
        case .evaluatingBufferingRate: "evaluatingBuffer"
        case .noItemToPlay: "noItem"
        case nil: "none"
        default: reason?.rawValue ?? "unknown"
        }
    }

    static func buildStreamInfoByItag(_ streams: [PipedKit.MediaStream]) -> [String: StreamDebugInfo] {
        streams.reduce(into: [:]) { result, stream in
            guard let rawURL = stream.url,
                let itag = queryValue("itag", in: rawURL),
                let width = stream.width,
                let height = stream.height,
                width > 0,
                height > 0
            else {
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

    static func info(for url: URL, in streamInfoByItag: [String: StreamDebugInfo]) -> StreamDebugInfo? {
        guard let itag = queryValue("itag", in: url.absoluteString) else { return nil }
        return streamInfoByItag[itag]
    }

    static func hlsItag(from uri: String?) -> String? {
        guard let uri,
            let expression = try? NSRegularExpression(pattern: #"[/&?]itag[/=](\d+)"#)
        else {
            return nil
        }
        let range = NSRange(uri.startIndex..<uri.endIndex, in: uri)
        guard let match = expression.firstMatch(in: uri, range: range),
            match.numberOfRanges > 1,
            let itagRange = Range(match.range(at: 1), in: uri)
        else {
            return nil
        }
        return String(uri[itagRange])
    }

    static func videoItag(from uri: String?) -> String? {
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
                let valueRange = Range(match.range(at: 1), in: raw)
            else {
                return nil
            }
            return String(raw[valueRange])
        }
    }

    static func renditionLabel(hlsItag: String?, videoItag: String?) -> String {
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

struct StreamDebugInfo {
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
