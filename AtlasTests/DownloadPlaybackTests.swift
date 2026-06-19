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

@Test func streamPlaybackPrefersComposedBeforeRegularHLS() throws {
    let detail = streamPlaybackDetail()
    let video = URL(string: "https://example.com/1080.mp4")!
    let audio = URL(string: "https://example.com/audio.m4a")!

    let source = try #require(StreamPlaybackBuilder.preferredSource(
        detail,
        allowAV1: false,
        preferredLanguages: ["en-US"]))

    #expect(source == .composed(video: video, audio: audio))
}

@Test func streamPlaybackPrefersPlayableAV1HLSEvenWhenHardwareProbeIsConservative() throws {
    let detail = streamPlaybackDetail(hls: "https://example.com/legacy.m3u8")
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
    let detail = streamPlaybackDetail(hls: "https://example.com/legacy.m3u8")
    let av1HLS = URL(string: "https://piped.example/hls/av1/WOzcFkld6_g/master.m3u8")!

    let playback = try #require(await StreamPlaybackBuilder.makePlayerItem(
        detail,
        allowAV1: false,
        av1HLSURL: av1HLS,
        preferredLanguages: ["en-US"]))

    #expect(!playback.composed)
    #expect(playback.sourceName == "direct-av1-hls")
    #expect(playback.failureFallback == .composedOrDirect)
    #expect(playback.selectsPreferredAudio)
}

@Test func av1HLSModePrefersComposedButKeepsHLSFallback() throws {
    let hls = URL(string: "https://example.com/master.m3u8")!
    let playlistDetail = streamPlaybackDetail(hls: hls.absoluteString)
    let video = URL(string: "https://example.com/1080.mp4")!
    let audio = URL(string: "https://example.com/audio.m4a")!

    let composedSource = try #require(StreamPlaybackBuilder.preferredSource(
        playlistDetail,
        allowAV1: true,
        allowProgressiveFallback: false,
        preferredLanguages: ["en-US"]))
    let hlsOnlySource = try #require(StreamPlaybackBuilder.preferredSource(
        streamPlaybackDetail(hls: hls.absoluteString, includeComposedStreams: false),
        allowAV1: true,
        allowProgressiveFallback: false,
        preferredLanguages: ["en-US"]))

    #expect(composedSource == .composed(video: video, audio: audio))
    #expect(hlsOnlySource == .direct(hls))
}

@Test func av1HLSModePrefersComposedOverFallbackPlaylist() throws {
    let detail = streamPlaybackDetail(hls: "https://example.com/master.m3u8")
    let video = URL(string: "https://example.com/1080.mp4")!
    let audio = URL(string: "https://example.com/audio.m4a")!

    let source = try #require(StreamPlaybackBuilder.preferredSource(
        detail,
        allowAV1: true,
        allowProgressiveFallback: false,
        preferredLanguages: ["en-US"]))

    #expect(source == .composed(video: video, audio: audio))
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
}

@Test func av1FallbackPrefersComposedSource() throws {
    let detail = streamPlaybackDetail(hls: "https://example.com/master.m3u8")
    let video = URL(string: "https://example.com/1080.mp4")!
    let audio = URL(string: "https://example.com/audio.m4a")!

    let source = try #require(StreamPlaybackBuilder.preferredSource(
        detail,
        allowAV1: true,
        allowProgressiveFallback: false,
        preferredLanguages: ["en-US"]))

    #expect(source == .composed(video: video, audio: audio))
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
        hls: "https://example.com/master.m3u8",
        videoURL: "file:///atlas/missing-video.mp4",
        audioURL: "file:///atlas/missing-audio.m4a")

    let playback = try #require(await StreamPlaybackBuilder.makePlayerItem(
        detail,
        allowAV1: false,
        preferredLanguages: ["en-US"]))

    #expect(!playback.composed)
    #expect(playback.sourceName == "fallback-hls")
    #expect(playback.selectsPreferredAudio)
}

private func streamPlaybackDetail(
    hls: String? = "https://example.com/master.m3u8",
    includeComposedStreams: Bool = true,
    videoURL: String = "https://example.com/1080.mp4",
    audioURL: String = "https://example.com/audio.m4a"
) -> VideoDetail {
    VideoDetail(
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
        videoStreams: includeComposedStreams ? [
            Stream(
                url: videoURL,
                format: "MP4",
                quality: "1080p",
                mimeType: "video/mp4",
                codec: "avc1.640028",
                videoOnly: true,
                bitrate: nil,
                width: 1920,
                height: 1080,
                fps: 30)
        ] : [],
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
