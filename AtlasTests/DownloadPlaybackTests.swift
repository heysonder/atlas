import Foundation
import PipedKit
import Testing
@testable import Atlas

@MainActor
@Test func playRequestFromDownloadCarriesLocalCaptionMetadata() {
    let download = DownloadedVideo(
        videoID: "v1",
        title: "Saved Video",
        uploader: "Uploader",
        fileName: "v1.mp4",
        thumbnailFileName: "v1.thumb",
        captionFileName: "v1.captions.vtt",
        captionMimeType: "text/vtt")

    let request = PlayRequest(download: download, fallbackThumbnail: "remote-thumb")

    #expect(request.videoID == "v1")
    #expect(request.localURL == download.fileURL)
    #expect(request.localCaptionURL == download.captionURL)
    #expect(request.localCaptionMimeType == "text/vtt")
    #expect(request.thumbnail == download.thumbnailURL?.absoluteString)
}

@MainActor
@Test func addToQueueAtEndIsAvailableOnlyAfterQueueHasItems() {
    let app = makeQueueTestApp()
    let first = PlayRequest(videoID: "first", title: "First")
    let second = PlayRequest(videoID: "second", title: "Second")

    #expect(!app.canAddToQueueAtEnd)

    app.playNext(first)

    #expect(app.canAddToQueueAtEnd)
    #expect(app.queuedVideos.map(\.request.videoID) == ["first"])

    app.addToQueue(second)
    app.addToQueue(first)

    #expect(app.queuedVideos.map(\.request.videoID) == ["first", "second", "first"])

    app.clearQueue()

    #expect(!app.canAddToQueueAtEnd)
}

@Test func composedOvertakesRegularHLSOnQualityTie() throws {
    let video = URL(string: "https://example.com/1080.mp4")!
    let audio = URL(string: "https://example.com/audio.m4a")!
    // The ladder tops out at the same 1080p as the composed pair, so the
    // guaranteed-top-rung composition wins the tie.
    let detail = streamPlaybackDetail(hls: "https://example.com/master.m3u8")

    let source = try #require(StreamPlaybackBuilder.preferredSource(
        detail,
        allowAV1: false,
        preferredLanguages: ["en-US"]))

    #expect(source == .composed(video: video, audio: audio))
}

@Test func qualityTieStartsOnHLSMasterWhileComposedAssembles() async throws {
    let detail = streamPlaybackDetail(hls: "https://example.com/master.m3u8")

    let playback = try #require(await StreamPlaybackBuilder.makePlayerItem(
        detail,
        allowAV1: false,
        preferredLanguages: ["en-US"]))

    // The composition wins the quality tie but takes seconds to assemble, so
    // playback starts on the master and carries the pending upgrade.
    #expect(!playback.composed)
    #expect(playback.sourceName == "direct-hls")
    #expect(playback.failureFallback == .composedOrDirect)
    #expect(playback.composedUpgrade == StreamPlaybackBuilder.ComposedUpgrade(
        video: URL(string: "https://example.com/1080.mp4")!,
        audio: URL(string: "https://example.com/audio.m4a")!))
}

@Test func sharperComposedStartsOnAV1HLSWhileAssembling() async throws {
    let av1HLS = URL(string: "https://piped.example/hls/av1/WOzcFkld6_g/master.m3u8")!
    // The AV1 master tops out at 720p, so the 1080p composition outranks it —
    // but the AV1 master still plays in the interim.
    let detail = streamPlaybackDetail(
        av1StreamURL: "https://example.com/720-av1.mp4", av1StreamHeight: 720)

    let playback = try #require(await StreamPlaybackBuilder.makePlayerItem(
        detail,
        allowAV1: false,
        av1HLSURL: av1HLS,
        preferredLanguages: ["en-US"]))

    #expect(playback.sourceName == "direct-av1-hls")
    #expect(playback.composedUpgrade != nil)
}

@Test func regularHLSWinsWhenLadderReachesHigherThanComposed() throws {
    let hls = URL(string: "https://example.com/master.m3u8")!
    // A 1440p VP9 rung raises the ladder's ceiling above the 1080p H.264
    // composition (VP9 isn't compose-able on iOS), so ABR keeps priority.
    let detail = streamPlaybackDetail(hls: hls.absoluteString, vp9StreamHeight: 1440)

    let source = try #require(StreamPlaybackBuilder.preferredSource(
        detail,
        allowAV1: false,
        preferredLanguages: ["en-US"]))

    #expect(source == .direct(hls))
}

@Test func streamPlaybackUsesComposedWhenHLSIsMissing() throws {
    let detail = streamPlaybackDetail(hls: nil)
    let video = URL(string: "https://example.com/1080.mp4")!
    let audio = URL(string: "https://example.com/audio.m4a")!

    let source = try #require(StreamPlaybackBuilder.preferredSource(
        detail,
        allowAV1: false,
        preferredLanguages: ["en-US"]))

    #expect(source == .composed(video: video, audio: audio))
}

@Test func streamPlaybackPrefersPlayableAV1HLSEvenWhenHardwareProbeIsConservative() throws {
    let detail = streamPlaybackDetail(
        hls: "https://example.com/legacy.m3u8",
        av1StreamURL: "https://example.com/2160-av1.mp4")
    let av1HLS = URL(string: "https://piped.example/hls/av1/WOzcFkld6_g/master.m3u8")!

    let av1Source = try #require(StreamPlaybackBuilder.preferredSource(
        detail,
        allowAV1: true,
        av1HLSURL: av1HLS,
        preferredLanguages: ["en-US"]))
    let conservativeProbeSource = try #require(StreamPlaybackBuilder.preferredSource(
        detail,
        allowAV1: false,
        av1HLSURL: av1HLS,
        preferredLanguages: ["en-US"]))

    #expect(av1Source == .direct(av1HLS))
    #expect(conservativeProbeSource == .direct(av1HLS))
}

@Test func streamPlaybackBuildsAV1HLSWithoutManifestPreflight() async throws {
    let detail = streamPlaybackDetail(
        hls: "https://example.com/legacy.m3u8",
        av1StreamURL: "https://example.com/2160-av1.mp4")
    let av1HLS = URL(string: "https://piped.example/hls/av1/WOzcFkld6_g/master.m3u8")!

    let playback = try #require(await StreamPlaybackBuilder.makePlayerItem(
        detail,
        allowAV1: false,
        av1HLSURL: av1HLS,
        preferredLanguages: ["en-US"]))

    #expect(!playback.composed)
    #expect(playback.sourceName == "direct-av1-hls")
    #expect(playback.failureFallback == .composedOrDirect)
    #expect(!playback.selectsPreferredAudio)
    #expect(playback.stallFallbackDelay == StreamPlaybackBuilder.av1HLSStallFallbackDelay)
    #expect(playback.item.preferredPeakBitRate == 0)
    #expect(playback.item.preferredMaximumResolution == .zero)
    #expect(playback.item.preferredForwardBufferDuration == 0)
}

@Test func composedOvertakesAV1HLSOnlyWhenStrictlySharper() throws {
    let av1HLS = URL(string: "https://piped.example/hls/av1/WOzcFkld6_g/master.m3u8")!
    let video = URL(string: "https://example.com/1080.mp4")!
    let audio = URL(string: "https://example.com/audio.m4a")!

    // The AV1 master tops out at 720p, so the 1080p composed pair is sharper.
    let sharperComposed = try #require(StreamPlaybackBuilder.preferredSource(
        streamPlaybackDetail(av1StreamURL: "https://example.com/720-av1.mp4", av1StreamHeight: 720),
        allowAV1: false,
        av1HLSURL: av1HLS,
        preferredLanguages: ["en-US"]))
    // The AV1 master matches the composed pair's ceiling, so ABR wins the tie.
    let matchedComposed = try #require(StreamPlaybackBuilder.preferredSource(
        streamPlaybackDetail(av1StreamURL: "https://example.com/2160-av1.mp4"),
        allowAV1: true,
        av1HLSURL: av1HLS,
        preferredLanguages: ["en-US"]))

    #expect(sharperComposed == .composed(video: video, audio: audio))
    #expect(matchedComposed == .direct(av1HLS))
}

@Test func composedAV1OvertakesRegularHLSWhenLadderTopsLower() throws {
    let av1Video = URL(string: "https://example.com/2160-av1.mp4")!
    let audio = URL(string: "https://example.com/audio.m4a")!

    // No AV1 HLS endpoint in play; YouTube's ladder (non-AV1) tops at 1080p,
    // so the 2160p AV1 composition is strictly sharper than the HLS master.
    let source = try #require(StreamPlaybackBuilder.preferredSource(
        streamPlaybackDetail(av1StreamURL: av1Video.absoluteString),
        allowAV1: true,
        preferredLanguages: ["en-US"]))

    #expect(source == .composed(video: av1Video, audio: audio))
}

@Test func unknownManifestHeightsTrustABR() throws {
    let av1HLS = URL(string: "https://piped.example/hls/av1/WOzcFkld6_g/master.m3u8")!

    // The AV1 stream reports no height, so no ceiling can be established and
    // the composed override must not fire.
    let source = try #require(StreamPlaybackBuilder.preferredSource(
        streamPlaybackDetail(av1StreamURL: "https://example.com/unknown-av1.mp4", av1StreamHeight: nil),
        allowAV1: false,
        av1HLSURL: av1HLS,
        preferredLanguages: ["en-US"]))

    #expect(source == .direct(av1HLS))
}

@Test func regularHLSWinsWhenNoComposedPairExists() throws {
    let hls = URL(string: "https://example.com/master.m3u8")!

    let source = try #require(StreamPlaybackBuilder.preferredSource(
        streamPlaybackDetail(hls: hls.absoluteString, includeComposedStreams: false),
        allowAV1: true,
        allowProgressiveFallback: false,
        preferredLanguages: ["en-US"]))

    #expect(source == .direct(hls))
}

@Test func regularHLSPlaybackKeepsComposedFailureFallback() async throws {
    // The taller VP9 rung keeps the master ahead of the composition so this
    // exercises the direct-hls startup path.
    let detail = streamPlaybackDetail(vp9StreamHeight: 1440)

    let playback = try #require(await StreamPlaybackBuilder.makePlayerItem(
        detail,
        allowAV1: false,
        preferredLanguages: ["en-US"]))

    #expect(!playback.composed)
    #expect(playback.sourceName == "direct-hls")
    #expect(playback.failureFallback == .composedOrDirect)
    #expect(playback.selectsPreferredAudio)
    #expect(playback.stallFallbackDelay == StreamPlaybackBuilder.defaultStallFallbackDelay)
    #expect(playback.composedUpgrade == nil)
}

@Test func detectsAV1HLSMasterManifest() {
    let manifest = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=11732129,CODECS="av01.0.12M.08,mp4a.40.2",RESOLUTION=3840x1920,FRAME-RATE=30,AUDIO="aac"
    /hls/av1/WOzcFkld6_g/video/401
    """

    #expect(StreamPlaybackBuilder.manifestAdvertisesAV1Video(manifest))
    #expect(!StreamPlaybackBuilder.manifestAdvertisesAV1Video("#EXTM3U\n#EXT-X-VERSION:7"))
}

@Test func directHLSFallbackSelectsPreferredAudio() throws {
    let detail = streamPlaybackDetail(hls: "https://example.com/master.m3u8")

    let playback = try #require(StreamPlaybackBuilder.makeDirectFailureFallbackItem(for: detail))

    #expect(!playback.composed)
    #expect(playback.sourceName == "fallback-hls")
    #expect(playback.selectsPreferredAudio)
    #expect(playback.stallFallbackDelay == StreamPlaybackBuilder.defaultStallFallbackDelay)
}

@Test func av1FallbackUsesDirectWhenComposedIsUnavailable() async throws {
    let detail = streamPlaybackDetail(
        hls: "https://example.com/master.m3u8",
        includeComposedStreams: false)

    let playback = try #require(await StreamPlaybackBuilder.makeComposedOrDirectFailureFallbackItem(
        detail,
        allowAV1: true,
        preferredLanguages: ["en-US"]))

    #expect(!playback.composed)
    #expect(playback.sourceName == "fallback-hls")
    #expect(playback.selectsPreferredAudio)
}

@Test func composedStartupFallsBackToDirectWhenAssemblyFails() async throws {
    let detail = streamPlaybackDetail(
        hls: nil,
        videoURL: "file:///atlas/missing-video.mp4",
        audioURL: "file:///atlas/missing-audio.m4a",
        progressiveURL: "https://example.com/720-progressive.mp4")

    let playback = try #require(await StreamPlaybackBuilder.makePlayerItem(
        detail,
        allowAV1: false,
        preferredLanguages: ["en-US"]))

    #expect(!playback.composed)
    #expect(playback.sourceName == "fallback-direct")
    #expect(playback.selectsPreferredAudio)
}

private func streamPlaybackDetail(
    hls: String? = "https://example.com/master.m3u8",
    includeComposedStreams: Bool = true,
    videoURL: String = "https://example.com/1080.mp4",
    audioURL: String = "https://example.com/audio.m4a",
    av1StreamURL: String? = nil,
    av1StreamHeight: Int? = 2160,
    progressiveURL: String? = nil,
    vp9StreamHeight: Int? = nil
) -> VideoDetail {
    var videoStreams: [PipedKit.Stream] = []
    if includeComposedStreams {
        videoStreams.append(Stream(
            url: videoURL,
            format: "MP4",
            quality: "1080p",
            mimeType: "video/mp4",
            codec: "avc1.640028",
            videoOnly: true,
            bitrate: nil,
            width: 1920,
            height: 1080,
            fps: 30))
    }
    if let vp9StreamHeight {
        videoStreams.append(Stream(
            url: "https://example.com/\(vp9StreamHeight)-vp9.webm",
            format: "WEBM",
            quality: "\(vp9StreamHeight)p",
            mimeType: "video/webm",
            codec: "vp9",
            videoOnly: true,
            bitrate: nil,
            width: vp9StreamHeight * 16 / 9,
            height: vp9StreamHeight,
            fps: 30))
    }
    if let av1StreamURL {
        videoStreams.append(Stream(
            url: av1StreamURL,
            format: "MP4",
            quality: av1StreamHeight.map { "\($0)p" },
            mimeType: "video/mp4",
            codec: "av01.0.12M.08",
            videoOnly: true,
            bitrate: nil,
            width: av1StreamHeight.map { $0 * 16 / 9 },
            height: av1StreamHeight,
            fps: 30))
    }
    if let progressiveURL {
        videoStreams.append(Stream(
            url: progressiveURL,
            format: "MP4",
            quality: "720p",
            mimeType: "video/mp4",
            codec: "avc1.4d401f",
            videoOnly: false,
            bitrate: nil,
            width: 1280,
            height: 720,
            fps: 30))
    }
    return VideoDetail(
        title: "Fast Start",
        description: nil,
        uploader: nil,
        uploaderUrl: nil,
        uploaderAvatar: nil,
        thumbnailUrl: nil,
        hls: hls,
        duration: 120,
        views: nil,
        likes: nil,
        uploaded: nil,
        uploaderVerified: nil,
        uploaderSubscriberCount: nil,
        creators: nil,
        livestream: nil,
        chapters: nil,
        videoStreams: videoStreams,
        audioStreams: includeComposedStreams ? [
            Stream(
                url: audioURL,
                format: "M4A",
                quality: nil,
                mimeType: "audio/mp4",
                codec: nil,
                videoOnly: nil,
                bitrate: 128000,
                width: nil,
                height: nil,
                fps: nil,
                languageCode: "en")
        ] : [],
        subtitles: nil,
        relatedStreams: nil,
        category: nil,
        tags: nil)
}

@MainActor
private func makeQueueTestApp() -> AppModel {
    let suiteName = "atlas.queue.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let instanceStore = InstanceStore(defaults: defaults, secureStore: QueueMemoryInstanceSecureStore())
    return AppModel(instanceStore: instanceStore)
}

private final class QueueMemoryInstanceSecureStore: InstanceSecureStoring {
    func loadInstanceURL() -> String? {
        nil
    }

    func saveInstanceURL(_ value: String) {}

    func clearInstanceURL() {}
}
