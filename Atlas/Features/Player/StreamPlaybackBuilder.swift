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
        case composedOrDirect
    }

    struct PreparedPlayback {
        let item: AVPlayerItem
        let composed: Bool
        let sourceName: String
        let failureFallback: FailureFallback
        let selectsPreferredAudio: Bool
        let stallFallbackDelay: TimeInterval
    }

    static let defaultStallFallbackDelay: TimeInterval = 15
    static let av1HLSStallFallbackDelay: TimeInterval = 45
    /// Remote composition assembly (track + duration loads through the proxy)
    /// is cancelled after this long, so a hung proxy degrades to the direct
    /// fallback instead of a spinner that never resolves.
    static let composedAssemblyTimeout: TimeInterval = 12
    /// Runtime fallbacks re-resolve stream URLs when the current details are
    /// older than this — a video's signed URLs all expire together, so
    /// rebuilding from stale details swaps one dead URL for another.
    static let staleDetailFallbackAge: TimeInterval = 30 * 60

    /// Builds the cleanest playable item first: an ABR manifest (AV1 HLS when
    /// the device and video support it, otherwise YouTube's own HLS master) so
    /// AVPlayer owns quality selection. The fixed-bitrate composed pair only
    /// takes over when it is strictly sharper than the best rung the manifest
    /// can offer; runtime fallback handles manifests that fail to play.
    static func makePlayerItem(
        _ detail: VideoDetail,
        allowAV1: Bool,
        av1HLSURL: URL? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) async -> PreparedPlayback? {
        if let av1HLSURL {
            clearCachedAV1HLSResponses(for: av1HLSURL)
            NSLog("Atlas.player: av1 hls candidate url=\(av1HLSURL.absoluteString)")
        }
        switch preferredSource(
            detail,
            allowAV1: allowAV1,
            av1HLSURL: av1HLSURL,
            allowProgressiveFallback: av1HLSURL == nil,
            preferredLanguages: preferredLanguages
        ) {
        case .direct(let url):
            let usesAV1HLS = url == av1HLSURL
            let usesHLS = usesAV1HLS || isHLSPlaylist(url)
            return PreparedPlayback(
                item: playerItem(forDirectURL: url, usesAV1HLS: usesAV1HLS),
                composed: false,
                sourceName: usesAV1HLS ? "direct-av1-hls" : (usesHLS ? "direct-hls" : "direct-initial"),
                failureFallback: usesHLS ? .composedOrDirect : .none,
                selectsPreferredAudio: !usesAV1HLS,
                stallFallbackDelay: usesAV1HLS ? av1HLSStallFallbackDelay : defaultStallFallbackDelay)
        case .composed(let video, let audio):
            guard let composed = await composedItem(
                video: video, audio: audio, timeout: composedAssemblyTimeout) else {
                NSLog("Atlas.player: composed startup assembly failed; falling back to direct")
                return makeDirectFailureFallbackItem(for: detail)
            }
            return PreparedPlayback(
                item: composed,
                composed: true,
                sourceName: "composed-initial",
                failureFallback: .direct,
                selectsPreferredAudio: true,
                stallFallbackDelay: defaultStallFallbackDelay)
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
        let composedSource = detail.bestComposedSource(
            allowAV1: allowAV1,
            preferredLanguages: preferredLanguages)
        // ABR manifests win by default; the fixed-bitrate composition can't
        // adapt to bandwidth at all, so it only takes over when it is strictly
        // sharper than the tallest rung the manifest is built from. When the
        // ceiling is unknown (no stream reports a height), trust the manifest.
        if let av1HLSURL {
            if let source = composedSource,
               let ceiling = detail.maxAV1VideoStreamHeight,
               source.height > ceiling {
                return .composed(video: source.video, audio: source.audio)
            }
            return .direct(av1HLSURL)
        }
        if let url = playlistURL(from: detail) {
            // YouTube's HLS master is built from the AVC/VP9 ladder, so an AV1
            // composition taller than that ladder beats it (e.g. an AV1 device
            // playing a video whose non-AV1 streams top out lower).
            if let source = composedSource,
               let ceiling = detail.maxNonAV1VideoStreamHeight,
               source.height > ceiling {
                return .composed(video: source.video, audio: source.audio)
            }
            return .direct(url)
        }
        if let source = composedSource {
            return .composed(video: source.video, audio: source.audio)
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
            selectsPreferredAudio: true,
            stallFallbackDelay: defaultStallFallbackDelay)
    }

    static func makeComposedOrDirectFailureFallbackItem(
        _ detail: VideoDetail,
        allowAV1: Bool,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) async -> PreparedPlayback? {
        let composedSource = detail.bestComposedSource(
            allowAV1: allowAV1,
            preferredLanguages: preferredLanguages)
        if let source = composedSource {
            if let composed = await composedItem(
                video: source.video, audio: source.audio, timeout: composedAssemblyTimeout) {
                return PreparedPlayback(
                    item: composed,
                    composed: true,
                    sourceName: "fallback-composed",
                    failureFallback: .none,
                    selectsPreferredAudio: true,
                    stallFallbackDelay: defaultStallFallbackDelay)
            }
            NSLog("Atlas.player: fallback composed assembly failed; falling back to direct")
        }
        return makeDirectFailureFallbackItem(for: detail)
    }

    static func manifestAdvertisesAV1Video(_ manifest: String) -> Bool {
        manifest.range(of: "#EXTM3U", options: .caseInsensitive) != nil
            && manifest.range(of: "#EXT-X-STREAM-INF", options: .caseInsensitive) != nil
            && manifest.range(of: "av01", options: .caseInsensitive) != nil
    }

    private static func playerItem(forDirectURL url: URL, usesAV1HLS: Bool) -> AVPlayerItem {
        // No bitrate/resolution/buffer caps: hand quality selection entirely to
        // AVPlayer's adaptive logic so it starts low and ramps up on its own.
        // AV1 HLS still uses a no-cache asset to avoid chasing stale signed URLs.
        usesAV1HLS ? AVPlayerItem(asset: av1HLSAsset(url: url)) : AVPlayerItem(url: url)
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

    private static func clearCachedAV1HLSResponses(for url: URL) {
        // AV1 HLS manifests lead to signed media URLs; stale cached playlist
        // responses can make AVPlayer chase expired ranges after server fixes.
        // Evict just this manifest's cached response instead of wiping the
        // shared cache (thumbnails, API responses); the asset's own requests
        // additionally send no-cache headers (see `av1HLSAsset`).
        URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
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
