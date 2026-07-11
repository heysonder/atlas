import Foundation
import PipedKit
import Testing

@testable import Atlas

@Test func composedOvertakesRegularHLSOnQualityTie() throws {
    let video = URL(string: "https://example.com/1080.mp4")!
    let audio = URL(string: "https://example.com/audio.m4a")!
    // The ladder tops out at the same 1080p as the composed pair, so the
    // guaranteed-top-rung composition wins the tie.
    let detail = streamPlaybackDetail(hls: "https://example.com/master.m3u8")

    let source = try #require(
        StreamPlaybackBuilder.preferredSource(
            detail,
            allowAV1: false,
            preferredLanguages: ["en-US"]))

    #expect(source == .composed(video: video, audio: audio))
}

@Test func qualityTieStartsOnHLSMasterWhileComposedAssembles() async throws {
    let detail = streamPlaybackDetail(hls: "https://example.com/master.m3u8")

    let playback = try #require(
        await StreamPlaybackBuilder.makePlayerItem(
            detail,
            allowAV1: false,
            preferredLanguages: ["en-US"]))

    // The composition wins the quality tie but takes seconds to assemble, so
    // playback starts on the master and carries the pending upgrade.
    #expect(!playback.composed)
    #expect(playback.sourceName == "direct-hls")
    #expect(playback.failureFallback == .composedOrDirect)
    #expect(
        playback.composedUpgrade
            == StreamPlaybackBuilder.ComposedUpgrade(
                video: URL(string: "https://example.com/1080.mp4")!,
                audio: URL(string: "https://example.com/audio.m4a")!))
}

@Test func sharperComposedStartsOnAV1HLSWhileAssembling() async throws {
    let av1HLS = URL(string: "https://example.com/hls/av1/WOzcFkld6_g/master.m3u8")!
    // The AV1 master tops out at 720p, so the 1080p composition outranks it —
    // but the AV1 master still plays in the interim.
    let detail = streamPlaybackDetail(
        av1StreamURL: "https://example.com/720-av1.mp4", av1StreamHeight: 720)

    let playback = try #require(
        await StreamPlaybackBuilder.makePlayerItem(
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

    let source = try #require(
        StreamPlaybackBuilder.preferredSource(
            detail,
            allowAV1: false,
            preferredLanguages: ["en-US"]))

    #expect(source == .direct(hls))
}

@Test func streamPlaybackUsesComposedWhenHLSIsMissing() throws {
    let detail = streamPlaybackDetail(hls: nil)
    let video = URL(string: "https://example.com/1080.mp4")!
    let audio = URL(string: "https://example.com/audio.m4a")!

    let source = try #require(
        StreamPlaybackBuilder.preferredSource(
            detail,
            allowAV1: false,
            preferredLanguages: ["en-US"]))

    #expect(source == .composed(video: video, audio: audio))
}

@Test func streamPlaybackPrefersPlayableAV1HLSEvenWhenHardwareProbeIsConservative() throws {
    let detail = streamPlaybackDetail(
        hls: "https://example.com/legacy.m3u8",
        av1StreamURL: "https://example.com/2160-av1.mp4")
    let av1HLS = URL(string: "https://example.com/hls/av1/WOzcFkld6_g/master.m3u8")!

    let av1Source = try #require(
        StreamPlaybackBuilder.preferredSource(
            detail,
            allowAV1: true,
            av1HLSURL: av1HLS,
            preferredLanguages: ["en-US"]))
    let conservativeProbeSource = try #require(
        StreamPlaybackBuilder.preferredSource(
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
    let av1HLS = URL(string: "https://example.com/hls/av1/WOzcFkld6_g/master.m3u8")!

    let playback = try #require(
        await StreamPlaybackBuilder.makePlayerItem(
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
    let av1HLS = URL(string: "https://example.com/hls/av1/WOzcFkld6_g/master.m3u8")!
    let video = URL(string: "https://example.com/1080.mp4")!
    let audio = URL(string: "https://example.com/audio.m4a")!

    // The AV1 master tops out at 720p, so the 1080p composed pair is sharper.
    let sharperComposed = try #require(
        StreamPlaybackBuilder.preferredSource(
            streamPlaybackDetail(av1StreamURL: "https://example.com/720-av1.mp4", av1StreamHeight: 720),
            allowAV1: false,
            av1HLSURL: av1HLS,
            preferredLanguages: ["en-US"]))
    // The AV1 master matches the composed pair's ceiling, so ABR wins the tie.
    let matchedComposed = try #require(
        StreamPlaybackBuilder.preferredSource(
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
    let source = try #require(
        StreamPlaybackBuilder.preferredSource(
            streamPlaybackDetail(av1StreamURL: av1Video.absoluteString),
            allowAV1: true,
            preferredLanguages: ["en-US"]))

    #expect(source == .composed(video: av1Video, audio: audio))
}

@Test func unknownManifestHeightsTrustABR() throws {
    let av1HLS = URL(string: "https://example.com/hls/av1/WOzcFkld6_g/master.m3u8")!

    // The AV1 stream reports no height, so no ceiling can be established and
    // the composed override must not fire.
    let source = try #require(
        StreamPlaybackBuilder.preferredSource(
            streamPlaybackDetail(av1StreamURL: "https://example.com/unknown-av1.mp4", av1StreamHeight: nil),
            allowAV1: false,
            av1HLSURL: av1HLS,
            preferredLanguages: ["en-US"]))

    #expect(source == .direct(av1HLS))
}

@Test func regularHLSWinsWhenNoComposedPairExists() throws {
    let hls = URL(string: "https://example.com/master.m3u8")!

    let source = try #require(
        StreamPlaybackBuilder.preferredSource(
            streamPlaybackDetail(hls: hls.absoluteString, includeComposedStreams: false),
            allowAV1: true,
            allowProgressiveFallback: false,
            preferredLanguages: ["en-US"]))

    #expect(source == .direct(hls))
}

@Test func directHLSFallbackSelectsPreferredAudio() throws {
    let detail = streamPlaybackDetail(hls: "https://example.com/master.m3u8")

    let playback = try #require(StreamPlaybackBuilder.makeDirectFailureFallbackItem(for: detail))

    #expect(!playback.composed)
    #expect(playback.sourceName == "fallback-hls")
    #expect(playback.selectsPreferredAudio)
    #expect(playback.stallFallbackDelay == StreamPlaybackBuilder.defaultStallFallbackDelay)
}
