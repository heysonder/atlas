import AVFoundation
import CoreMedia
import PipedKit

enum StreamPlaybackBuilder {
    enum PlaybackSource: Equatable {
        case direct(URL)
        case composed(video: URL, audio: URL)
    }

    enum FailureFallback: Equatable {
        case none
        case direct
        case hlsOrComposed
    }

    struct PreparedPlayback {
        let item: AVPlayerItem
        let composed: Bool
        let sourceName: String
        let allowsComposedUpgrade: Bool
        let failureFallback: FailureFallback
        let selectsPreferredAudio: Bool
    }

    /// Builds the fastest playable item first. Direct HLS/progressive playback
    /// lets AVPlayer start buffering immediately; composing separate video/audio
    /// tracks is kept only for videos that expose no direct playable URL.
    static func makePlayerItem(
        _ detail: VideoDetail,
        allowAV1: Bool,
        av1HLSURL: URL? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) async -> PreparedPlayback? {
        let validatedAV1HLSURL = await usableAV1HLSURL(av1HLSURL)
        if let av1HLSURL, validatedAV1HLSURL == nil {
            NSLog("Atlas.player: av1 hls unavailable candidate=\(av1HLSURL.absoluteString)")
        }
        let fallbackPlaylistMaxHeight = await fallbackPlaylistMaxHeight(
            for: detail,
            compareAfterAV1Failure: av1HLSURL != nil && validatedAV1HLSURL == nil)
        switch preferredSource(
            detail,
            allowAV1: allowAV1,
            av1HLSURL: validatedAV1HLSURL,
            allowProgressiveFallback: av1HLSURL == nil,
            playlistMaxHeight: fallbackPlaylistMaxHeight,
            preferredLanguages: preferredLanguages
        ) {
        case .direct(let url):
            let usesAV1HLS = url == validatedAV1HLSURL
            let usesHLS = isHLSPlaylist(url)
            return PreparedPlayback(
                item: playerItem(forDirectURL: url, usesAV1HLS: usesAV1HLS),
                composed: false,
                sourceName: usesAV1HLS ? "direct-av1-hls" : "direct-initial",
                allowsComposedUpgrade: !usesHLS && detail.bestComposedSource(
                    allowAV1: allowAV1,
                    preferredLanguages: preferredLanguages
                ) != nil,
                failureFallback: usesAV1HLS ? .hlsOrComposed : .none,
                selectsPreferredAudio: !usesHLS)
        case .composed(let video, let audio):
            guard let composed = await composedItem(video: video, audio: audio) else { return nil }
            return PreparedPlayback(
                item: composed,
                composed: true,
                sourceName: "composed-initial",
                allowsComposedUpgrade: false,
                failureFallback: av1HLSURL == nil ? .direct : .none,
                selectsPreferredAudio: true)
        case nil:
            return nil
        }
    }

    static func preferredSource(
        _ detail: VideoDetail,
        allowAV1: Bool,
        av1HLSURL: URL? = nil,
        allowProgressiveFallback: Bool = true,
        playlistMaxHeight: Int? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> PlaybackSource? {
        if let av1HLSURL { return .direct(av1HLSURL) }
        let composedSource = detail.bestComposedSource(
            allowAV1: allowAV1,
            preferredLanguages: preferredLanguages)
        if let url = playlistURL(from: detail) {
            if let source = composedSource,
               shouldPreferComposedSource(source, overPlaylistMaxHeight: playlistMaxHeight) {
                return .composed(video: source.video, audio: source.audio)
            }
            return .direct(url)
        }
        if allowProgressiveFallback, let url = detail.playableURL { return .direct(url) }
        guard let source = composedSource else {
            return nil
        }
        return .composed(video: source.video, audio: source.audio)
    }

    static func fallbackPlayerItem(for detail: VideoDetail) -> AVPlayerItem? {
        makeFastStartPlayerItem(detail)
    }

    static func makeDirectFailureFallbackItem(for detail: VideoDetail) -> PreparedPlayback? {
        guard let item = fallbackPlayerItem(for: detail) else { return nil }
        return PreparedPlayback(
            item: item,
            composed: false,
            sourceName: "fallback-direct",
            allowsComposedUpgrade: false,
            failureFallback: .none,
            selectsPreferredAudio: true)
    }

    static func makeHLSOrComposedFailureFallbackItem(
        _ detail: VideoDetail,
        allowAV1: Bool,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) async -> PreparedPlayback? {
        let playlistMaxHeight = await fallbackPlaylistMaxHeight(
            for: detail,
            compareAfterAV1Failure: true)
        switch preferredSource(
            detail,
            allowAV1: allowAV1,
            allowProgressiveFallback: false,
            playlistMaxHeight: playlistMaxHeight,
            preferredLanguages: preferredLanguages
        ) {
        case .direct(let url):
            let usesHLS = isHLSPlaylist(url)
            return PreparedPlayback(
                item: playerItem(forDirectURL: url, usesAV1HLS: false),
                composed: false,
                sourceName: usesHLS ? "fallback-hls" : "fallback-direct",
                allowsComposedUpgrade: false,
                failureFallback: .none,
                selectsPreferredAudio: !usesHLS)
        case .composed(let video, let audio):
            guard let composed = await composedItem(video: video, audio: audio) else { return nil }
            return PreparedPlayback(
                item: composed,
                composed: true,
                sourceName: "fallback-composed",
                allowsComposedUpgrade: false,
                failureFallback: .none,
                selectsPreferredAudio: true)
        case nil:
            return nil
        }
    }

    static func makeComposedPlayerItem(
        _ detail: VideoDetail,
        allowAV1: Bool,
        preferredLanguages: [String] = Locale.preferredLanguages,
        timeout: TimeInterval? = nil
    ) async -> AVPlayerItem? {
        guard let source = detail.bestComposedSource(
            allowAV1: allowAV1,
            preferredLanguages: preferredLanguages
        ) else {
            return nil
        }
        return await composedItem(video: source.video, audio: source.audio, timeout: timeout)
    }

    /// Builds the fastest item AVPlayer can open directly. HLS is adaptive, and
    /// progressive mp4 is a simple fallback; neither requires probing separate
    /// audio/video tracks before the first frame can start.
    static func makeFastStartPlayerItem(_ detail: VideoDetail) -> AVPlayerItem? {
        guard let url = detail.playableURL else { return nil }
        return AVPlayerItem(url: url)
    }

    static func manifestAdvertisesAV1Video(_ manifest: String) -> Bool {
        manifest.range(of: "#EXTM3U", options: .caseInsensitive) != nil
            && manifest.range(of: "#EXT-X-STREAM-INF", options: .caseInsensitive) != nil
            && manifest.range(of: "av01", options: .caseInsensitive) != nil
    }

    static func maximumAdvertisedHLSHeight(_ manifest: String) -> Int? {
        guard let expression = try? NSRegularExpression(
            pattern: #"RESOLUTION\s*=\s*\d+x(\d+)"#,
            options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(manifest.startIndex..<manifest.endIndex, in: manifest)
        return expression.matches(in: manifest, range: range)
            .compactMap { match -> Int? in
                guard match.numberOfRanges > 1,
                      let heightRange = Range(match.range(at: 1), in: manifest) else {
                    return nil
                }
                return Int(manifest[heightRange])
            }
            .max()
    }

    private static func usableAV1HLSURL(_ url: URL?) async -> URL? {
        guard let url else { return nil }
        clearCachedAV1HLSResponses()
        let request = av1HLSManifestRequest(for: url)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                NSLog("Atlas.player: av1 hls manifest http=\(http.statusCode) url=\(url.absoluteString)")
                return nil
            }
            guard let manifest = String(data: data, encoding: .utf8),
                  manifestAdvertisesAV1Video(manifest) else {
                NSLog("Atlas.player: av1 hls manifest missing av01 url=\(url.absoluteString)")
                return nil
            }
            NSLog("Atlas.player: av1 hls master ready url=\(url.absoluteString)")
            return url
        } catch {
            NSLog("Atlas.player: av1 hls validation failed url=\(url.absoluteString) error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func fallbackPlaylistMaxHeight(
        for detail: VideoDetail,
        compareAfterAV1Failure: Bool
    ) async -> Int? {
        guard compareAfterAV1Failure,
              let url = playlistURL(from: detail) else {
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: hlsManifestRequest(for: url))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                NSLog("Atlas.player: fallback hls manifest http=\(http.statusCode) url=\(url.absoluteString)")
                return nil
            }
            guard let manifest = String(data: data, encoding: .utf8) else { return nil }
            return maximumAdvertisedHLSHeight(manifest)
        } catch {
            NSLog("Atlas.player: fallback hls manifest failed url=\(url.absoluteString) error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func playerItem(forDirectURL url: URL, usesAV1HLS: Bool) -> AVPlayerItem {
        let item = usesAV1HLS ? AVPlayerItem(asset: av1HLSAsset(url: url)) : AVPlayerItem(url: url)
        if usesAV1HLS {
            item.preferredPeakBitRate = 0
            item.preferredForwardBufferDuration = 0
        }
        return item
    }

    private static func av1HLSManifestRequest(for url: URL) -> URLRequest {
        hlsManifestRequest(for: url)
    }

    private static func hlsManifestRequest(for url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 5)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private static func av1HLSAsset(url: URL) -> AVURLAsset {
        AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "Cache-Control": "no-cache",
                    "Pragma": "no-cache"
                ]
            ])
    }

    private static func clearCachedAV1HLSResponses() {
        // AV1 HLS manifests lead to signed media URLs; stale cached playlist
        // responses can make AVPlayer chase expired ranges after server fixes.
        URLCache.shared.removeAllCachedResponses()
    }

    private static func playlistURL(from detail: VideoDetail) -> URL? {
        guard let hls = detail.hls,
              !hls.isEmpty,
              let url = URL(string: hls),
              isHLSPlaylist(url) else {
            return nil
        }
        return url
    }

    private static func shouldPreferComposedSource(
        _ source: (video: URL, audio: URL, height: Int),
        overPlaylistMaxHeight playlistMaxHeight: Int?
    ) -> Bool {
        guard let playlistMaxHeight else { return false }
        return source.height > playlistMaxHeight
    }

    private static func isHLSPlaylist(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8"
            || url.absoluteString.range(of: ".m3u8", options: .caseInsensitive) != nil
    }

    private static func composedItem(
        video videoURL: URL,
        audio audioURL: URL,
        timeout: TimeInterval? = nil
    ) async -> AVPlayerItem? {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let timeoutTask = Task {
            guard let timeout else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            videoAsset.cancelLoading()
            audioAsset.cancelLoading()
        }
        defer { timeoutTask.cancel() }

        let composition = AVMutableComposition()
        do {
            guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
                  let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                return nil
            }
            let videoDuration = try await videoAsset.load(.duration)
            guard let composedVideo = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let composedAudio = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return nil
            }
            try composedVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
            let audioDuration = try await audioAsset.load(.duration)
            try composedAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: min(videoDuration, audioDuration)),
                of: audioTrack,
                at: .zero)
            return AVPlayerItem(asset: composition)
        } catch {
            return nil
        }
    }
}
