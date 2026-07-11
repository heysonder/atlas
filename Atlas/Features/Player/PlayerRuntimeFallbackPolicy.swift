import AVFoundation

enum PlayerRuntimeFallbackPolicy {
    static func hasAdvanced(from stalledAt: Double, to currentSeconds: Double) -> Bool {
        currentSeconds.isFinite
            && stalledAt.isFinite
            && currentSeconds > stalledAt + 0.75
    }

    /// CoreMedia status -12660 represents an HTTP 403 while loading media,
    /// which is the signature used for an expired signed stream URL.
    static func hasExpiredURLError(_ item: AVPlayerItem?) -> Bool {
        guard let event = item?.errorLog()?.events.last else { return false }
        return event.errorDomain == "CoreMediaErrorDomain"
            && event.errorStatusCode == -12660
    }
}
