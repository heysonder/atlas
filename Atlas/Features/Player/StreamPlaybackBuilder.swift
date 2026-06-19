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
        case composedOrHLS
    }

    struct PreparedPlayback {
        let item: AVPlayerItem
        let composed: Bool
        let sourceName: String
        let failureFallback: FailureFallback
        let selectsPreferredAudio: Bool
    }

    /// Builds the cleanest playable item first. AV1 HLS stays first when the
    /// instance supports it; otherwise the composed video/audio pair wins over
    /// regular direct URLs because Piped's direct stream is often lower quality.
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
        switch preferredSource(
            detail,
            allowAV1: allowAV1,
            av1HLSURL: validatedAV1HLSURL,
            allowProgressiveFallback: av1HLSURL == nil,
            preferredLanguages: preferredLanguages
        ) {
        case .direct(let url):
            let usesAV1HLS = url == validatedAV1HLSURL
            return PreparedPlayback(
                item: playerItem(forDirectURL: url, usesAV1HLS: usesAV1HLS),
                composed: false,
                sourceName: usesAV1HLS ? "direct-av1-hls" : "direct-initial",
                failureFallback: usesAV1HLS ? .composedOrHLS : .none,
                selectsPreferredAudio: true)
        case .composed(let video, let audio):
            guard let composed = await composedItem(video: video, audio: audio) else { return nil }
            return PreparedPlayback(
                item: composed,
                composed: true,
                sourceName: "composed-initial",
                failureFallback: .direct,
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
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> PlaybackSource? {
        if let av1HLSURL { return .direct(av1HLSURL) }
        let composedSource = detail.bestComposedSource(
            allowAV1: allowAV1,
            preferredLanguages: preferredLanguages)
        if let source = composedSource {
            return .composed(video: source.video, audio: source.audio)
        }
        if let url = playlistURL(from: detail) {
            return .direct(url)
        }
        if allowProgressiveFallback, let url = detail.playableURL { return .direct(url) }
        return nil
    }

    static func makeDirectFailureFallbackItem(for detail: VideoDetail) -> PreparedPlayback? {
        guard let url = detail.playableURL else { return nil }
        let usesHLS = isHLSPlaylist(url)
        return PreparedPlayback(
            item: playerItem(forDirectURL: url, usesAV1HLS: false),
            composed: false,
            sourceName: usesHLS ? "fallback-hls" : "fallback-direct",
            failureFallback: .none,
            selectsPreferredAudio: true)
    }

    static func makeComposedOrHLSFailureFallbackItem(
        _ detail: VideoDetail,
        allowAV1: Bool,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) async -> PreparedPlayback? {
        switch preferredSource(
            detail,
            allowAV1: allowAV1,
            allowProgressiveFallback: false,
            preferredLanguages: preferredLanguages
        ) {
        case .direct(let url):
            let usesHLS = isHLSPlaylist(url)
            return PreparedPlayback(
                item: playerItem(forDirectURL: url, usesAV1HLS: false),
                composed: false,
                sourceName: usesHLS ? "fallback-hls" : "fallback-direct",
                failureFallback: .none,
                selectsPreferredAudio: true)
        case .composed(let video, let audio):
            guard let composed = await composedItem(video: video, audio: audio) else { return nil }
            return PreparedPlayback(
                item: composed,
                composed: true,
                sourceName: "fallback-composed",
                failureFallback: .none,
                selectsPreferredAudio: true)
        case nil:
            return nil
        }
    }

    static func manifestAdvertisesAV1Video(_ manifest: String) -> Bool {
        manifest.range(of: "#EXTM3U", options: .caseInsensitive) != nil
            && manifest.range(of: "#EXT-X-STREAM-INF", options: .caseInsensitive) != nil
            && manifest.range(of: "av01", options: .caseInsensitive) != nil
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
