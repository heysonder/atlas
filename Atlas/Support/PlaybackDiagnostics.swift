import AVFoundation
import os

/// Structured playback diagnostics that deliberately exclude remote URLs,
/// filesystem paths, AVFoundation comments, and localized/upstream error text.
/// The remaining string tokens are allowlisted and bounded before logging.
@MainActor
enum PlaybackDiagnostics {
    private static let log = Logger(subsystem: "sh.cmf.atlas", category: "player")

    struct ErrorCode: Equatable, Sendable {
        let domain: String
        let code: Int
    }

    static func safeToken(_ value: String, maximumBytes: Int = 64) -> String {
        guard !value.isEmpty,
            value.utf8.count <= maximumBytes,
            value.unicodeScalars.allSatisfy({ scalar in
                switch scalar.value {
                case 45, 46, 48...57, 65...90, 95, 97...122: true
                default: false
                }
            })
        else { return "redacted" }
        return value
    }

    static func errorCode(_ error: Error?) -> ErrorCode? {
        guard let error else { return nil }
        let value = error as NSError
        return ErrorCode(domain: safeToken(value.domain), code: value.code)
    }

    static func itemErrorCode(_ item: AVPlayerItem?) -> ErrorCode? {
        if let event = item?.errorLog()?.events.last {
            return ErrorCode(
                domain: safeToken(event.errorDomain),
                code: event.errorStatusCode)
        }
        return errorCode(item?.error)
    }

    static func start(videoID: String, source: String) {
        log.debug(
            "start video=\(videoID, privacy: .private(mask: .hash)) source=\(safeToken(source), privacy: .public)")
    }

    static func itemEvent(
        _ event: String,
        videoID: String,
        source: String,
        item: AVPlayerItem?,
        notificationError: Error? = nil
    ) {
        let itemError = itemErrorCode(item)
        let notification = errorCode(notificationError)
        log.debug(
            "event=\(safeToken(event), privacy: .public) video=\(videoID, privacy: .private(mask: .hash)) source=\(safeToken(source), privacy: .public) itemDomain=\(itemError?.domain ?? "none", privacy: .public) itemCode=\(itemError?.code ?? 0, privacy: .public) notificationDomain=\(notification?.domain ?? "none", privacy: .public) notificationCode=\(notification?.code ?? 0, privacy: .public)"
        )
    }

    static func accessEvent(videoID: String, source: String, item: AVPlayerItem?) {
        guard let event = item?.accessLog()?.events.last else {
            log.debug(
                "event=access-missing video=\(videoID, privacy: .private(mask: .hash)) source=\(safeToken(source), privacy: .public)"
            )
            return
        }
        log.debug(
            "event=access video=\(videoID, privacy: .private(mask: .hash)) source=\(safeToken(source), privacy: .public) indicatedBitrate=\(event.indicatedBitrate, privacy: .public) observedBitrate=\(event.observedBitrate, privacy: .public) stalls=\(event.numberOfStalls, privacy: .public) bytes=\(event.numberOfBytesTransferred, privacy: .public)"
        )
    }

    static func timeControl(videoID: String, source: String, player: AVPlayer) {
        let item = player.currentItem
        let error = itemErrorCode(item)
        let seconds = player.currentTime().seconds
        let bufferEnd = item?.loadedTimeRanges
            .map(\.timeRangeValue)
            .map { $0.start.seconds + $0.duration.seconds }
            .filter(\.isFinite)
            .max()
        log.debug(
            "event=time-control video=\(videoID, privacy: .private(mask: .hash)) source=\(safeToken(source), privacy: .public) control=\(timeControlStatusName(player.timeControlStatus), privacy: .public) item=\(itemStatusName(item?.status), privacy: .public) likely=\(item?.isPlaybackLikelyToKeepUp ?? false, privacy: .public) empty=\(item?.isPlaybackBufferEmpty ?? false, privacy: .public) full=\(item?.isPlaybackBufferFull ?? false, privacy: .public) rate=\(player.rate, privacy: .public) seconds=\(seconds.isFinite ? seconds : -1, privacy: .public) bufferEnd=\(bufferEnd ?? -1, privacy: .public) errorDomain=\(error?.domain ?? "none", privacy: .public) errorCode=\(error?.code ?? 0, privacy: .public)"
        )
    }

    static func fallback(videoID: String, source: String, reason: String, item: AVPlayerItem?) {
        let error = itemErrorCode(item)
        log.debug(
            "event=fallback video=\(videoID, privacy: .private(mask: .hash)) source=\(safeToken(source), privacy: .public) reason=\(safeToken(reason), privacy: .public) errorDomain=\(error?.domain ?? "none", privacy: .public) errorCode=\(error?.code ?? 0, privacy: .public)"
        )
    }

    static func message(_ event: String, videoID: String? = nil, source: String? = nil) {
        log.debug(
            "event=\(safeToken(event), privacy: .public) video=\(videoID ?? "none", privacy: .private(mask: .hash)) source=\(safeToken(source ?? "none"), privacy: .public)"
        )
    }

    private static func itemStatusName(_ status: AVPlayerItem.Status?) -> String {
        switch status {
        case .unknown: "unknown"
        case .readyToPlay: "ready"
        case .failed: "failed"
        case nil: "missing"
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
}
