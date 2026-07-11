import Foundation
import PipedKit
import Testing

@testable import Atlas

@Test func regularHLSPlaybackKeepsComposedFailureFallback() async throws {
    // The taller VP9 rung keeps the master ahead of the composition so this
    // exercises the direct-hls startup path.
    let detail = streamPlaybackDetail(vp9StreamHeight: 1440)

    let playback = try #require(
        await StreamPlaybackBuilder.makePlayerItem(
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

@Test func av1FallbackUsesDirectWhenComposedIsUnavailable() async throws {
    let detail = streamPlaybackDetail(
        hls: "https://example.com/master.m3u8",
        includeComposedStreams: false)

    let playback = try #require(
        await StreamPlaybackBuilder.makeComposedOrDirectFailureFallbackItem(
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

    let playback = try #require(
        await StreamPlaybackBuilder.makePlayerItem(
            detail,
            allowAV1: false,
            preferredLanguages: ["en-US"]))

    #expect(!playback.composed)
    #expect(playback.sourceName == "fallback-direct")
    #expect(playback.selectsPreferredAudio)
}
