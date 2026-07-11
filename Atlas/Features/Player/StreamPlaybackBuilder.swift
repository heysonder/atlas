import AVFoundation
import CoreMedia
import PipedKit
import VideoToolbox

enum StreamPlaybackBuilder {
    /// Whether this device has hardware AV1 decode (iPhone 15 Pro / A17 Pro+).
    static let deviceSupportsAV1: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    enum PlaybackSource: Equatable {
        case direct(URL)
        case composed(video: URL, audio: URL)
    }

    enum FailureFallback: Equatable {
        case none
        case direct
        case composedOrDirect
    }

    /// A composition that outranks the manifest currently playing but wasn't
    /// assembled at startup (assembly loads remote tracks through the proxy,
    /// which takes seconds). The player assembles it in the background and
    /// swaps once it's ready.
    struct ComposedUpgrade: Equatable {
        let video: URL
        let audio: URL
    }

    struct PreparedPlayback {
        let item: AVPlayerItem
        let composed: Bool
        let sourceName: String
        let failureFallback: FailureFallback
        let selectsPreferredAudio: Bool
        let stallFallbackDelay: TimeInterval
        var composedUpgrade: ComposedUpgrade? = nil
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
    /// AVPlayer owns quality selection. The fixed-bitrate composed pair takes
    /// over when it is strictly sharper than the AV1 master's best rung, or at
    /// least matches YouTube's master (quality ties go to the composition);
    /// runtime fallback handles manifests that fail to play.
    static func makePlayerItem(
        _ detail: VideoDetail,
        allowAV1: Bool,
        av1HLSURL: URL? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages,
        client: PolicyHTTPClient = AppModel.publicHTTPClient
    ) async -> PreparedPlayback? {
        if let av1HLSURL {
            clearCachedAV1HLSResponses(for: av1HLSURL)
            PlaybackDiagnostics.message("av1-hls-candidate")
        }
        switch preferredSource(
            detail,
            allowAV1: allowAV1,
            av1HLSURL: av1HLSURL,
            allowProgressiveFallback: av1HLSURL == nil,
            preferredLanguages: preferredLanguages
        ) {
        case .direct(let url):
            return directPlayback(url: url, av1HLSURL: av1HLSURL, client: client)
        case .composed(let video, let audio):
            // Assembly takes seconds, so when a manifest exists play it right
            // away and hand the caller the pending composition to assemble in
            // the background and swap in once ready.
            if let manifestURL = av1HLSURL ?? playlistURL(from: detail) {
                return directPlayback(
                    url: manifestURL,
                    av1HLSURL: av1HLSURL,
                    client: client,
                    composedUpgrade: ComposedUpgrade(video: video, audio: audio))
            }
            guard
                let composed = await composedItem(
                    video: video,
                    audio: audio,
                    client: client,
                    timeout: composedAssemblyTimeout)
            else {
                PlaybackDiagnostics.message("composed-startup-failed")
                return makeDirectFailureFallbackItem(for: detail, client: client)
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

    private static func directPlayback(
        url: URL,
        av1HLSURL: URL?,
        client: PolicyHTTPClient,
        composedUpgrade: ComposedUpgrade? = nil
    ) -> PreparedPlayback? {
        let usesAV1HLS = url == av1HLSURL
        let usesHLS = usesAV1HLS || isHLSPlaylist(url)
        guard
            let item = playerItem(
                forDirectURL: url, usesAV1HLS: usesAV1HLS, client: client)
        else { return nil }
        return PreparedPlayback(
            item: item,
            composed: false,
            sourceName: usesAV1HLS ? "direct-av1-hls" : (usesHLS ? "direct-hls" : "direct-initial"),
            failureFallback: usesHLS ? .composedOrDirect : .none,
            selectsPreferredAudio: !usesAV1HLS,
            stallFallbackDelay: usesAV1HLS ? av1HLSStallFallbackDelay : defaultStallFallbackDelay,
            composedUpgrade: composedUpgrade)
    }

    /// Assembles the composition promised by `PreparedPlayback.composedUpgrade`.
    /// Nil when assembly fails or times out — the interim manifest keeps playing.
    static func makeComposedUpgradePlayback(
        _ upgrade: ComposedUpgrade,
        client: PolicyHTTPClient = AppModel.publicHTTPClient
    ) async -> PreparedPlayback? {
        guard
            let item = await composedItem(
                video: upgrade.video,
                audio: upgrade.audio,
                client: client,
                timeout: composedAssemblyTimeout)
        else {
            PlaybackDiagnostics.message("composed-upgrade-failed")
            return nil
        }
        return PreparedPlayback(
            item: item,
            composed: true,
            sourceName: "composed-upgrade",
            failureFallback: .direct,
            selectsPreferredAudio: true,
            stallFallbackDelay: defaultStallFallbackDelay)
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
                source.height > ceiling
            {
                return .composed(video: source.video, audio: source.audio)
            }
            return .direct(av1HLSURL)
        }
        if let url = playlistURL(from: detail) {
            // YouTube's HLS master is built from the AVC/VP9 ladder. It only
            // outranks the composed pair when that ladder can actually reach
            // *higher* — on a quality tie the composition wins, trading ABR for
            // a guaranteed top rung (user rule 2026-07-08). When the ceiling is
            // unknown, trust the manifest.
            if let source = composedSource,
                let ceiling = detail.maxNonAV1VideoStreamHeight,
                source.height >= ceiling
            {
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

    static func makeDirectFailureFallbackItem(
        for detail: VideoDetail,
        client: PolicyHTTPClient = AppModel.publicHTTPClient
    ) -> PreparedPlayback? {
        guard let url = detail.playableURL else { return nil }
        let usesHLS = isHLSPlaylist(url)
        guard
            let item = playerItem(
                forDirectURL: url, usesAV1HLS: false, client: client)
        else { return nil }
        return PreparedPlayback(
            item: item,
            composed: false,
            sourceName: usesHLS ? "fallback-hls" : "fallback-direct",
            failureFallback: .none,
            selectsPreferredAudio: true,
            stallFallbackDelay: defaultStallFallbackDelay)
    }

    static func makeComposedOrDirectFailureFallbackItem(
        _ detail: VideoDetail,
        allowAV1: Bool,
        preferredLanguages: [String] = Locale.preferredLanguages,
        client: PolicyHTTPClient = AppModel.publicHTTPClient
    ) async -> PreparedPlayback? {
        let composedSource = detail.bestComposedSource(
            allowAV1: allowAV1,
            preferredLanguages: preferredLanguages)
        if let source = composedSource {
            if let composed = await composedItem(
                video: source.video,
                audio: source.audio,
                client: client,
                timeout: composedAssemblyTimeout)
            {
                return PreparedPlayback(
                    item: composed,
                    composed: true,
                    sourceName: "fallback-composed",
                    failureFallback: .none,
                    selectsPreferredAudio: true,
                    stallFallbackDelay: defaultStallFallbackDelay)
            }
            PlaybackDiagnostics.message("composed-fallback-failed")
        }
        return makeDirectFailureFallbackItem(for: detail, client: client)
    }

    static func manifestAdvertisesAV1Video(_ manifest: String) -> Bool {
        manifest.range(of: "#EXTM3U", options: .caseInsensitive) != nil
            && manifest.range(of: "#EXT-X-STREAM-INF", options: .caseInsensitive) != nil
            && manifest.range(of: "av01", options: .caseInsensitive) != nil
    }

    private static func playerItem(
        forDirectURL url: URL,
        usesAV1HLS: Bool,
        client: PolicyHTTPClient
    ) -> AVPlayerItem? {
        // No bitrate/resolution/buffer caps: hand quality selection entirely to
        // AVPlayer's adaptive logic so it starts low and ramps up on its own.
        // AV1 HLS still uses a no-cache asset to avoid chasing stale signed URLs.
        guard
            let asset = try? PolicyMediaAssetFactory.asset(
                for: url, client: client, noCache: usesAV1HLS)
        else { return nil }
        return AVPlayerItem(asset: asset)
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
            isHLSPlaylist(url)
        else {
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
        client: PolicyHTTPClient,
        timeout: TimeInterval? = nil
    ) async -> AVPlayerItem? {
        guard let videoAsset = try? PolicyMediaAssetFactory.asset(for: videoURL, client: client),
            let audioAsset = try? PolicyMediaAssetFactory.asset(for: audioURL, client: client)
        else { return nil }
        let timeoutTask = Task {
            guard let timeout else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                try Task.checkCancellation()
            } catch {
                return
            }
            videoAsset.cancelLoading()
            audioAsset.cancelLoading()
        }
        defer { timeoutTask.cancel() }

        let composition = AVMutableComposition()
        do {
            guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
                let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
            else {
                return nil
            }
            let videoDuration = try await videoAsset.load(.duration)
            guard
                let composedVideo = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                let composedAudio = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else {
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
