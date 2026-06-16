import AVFoundation
import CoreMedia
import PipedKit

enum StreamPlaybackBuilder {
    /// Builds the highest-quality playable item: first try composing the best
    /// video-only + audio streams, then fall back to HLS/progressive playback.
    static func makePlayerItem(
        _ detail: VideoDetail,
        allowAV1: Bool,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) async -> (item: AVPlayerItem, composed: Bool)? {
        if let source = detail.bestComposedSource(allowAV1: allowAV1, preferredLanguages: preferredLanguages),
           let composed = await composedItem(video: source.video, audio: source.audio) {
            return (composed, true)
        }
        guard let fallback = fallbackPlayerItem(for: detail) else { return nil }
        return (fallback, false)
    }

    static func fallbackPlayerItem(for detail: VideoDetail) -> AVPlayerItem? {
        makeFastStartPlayerItem(detail)
    }

    /// Builds the fastest item AVPlayer can open directly. HLS is adaptive, and
    /// progressive mp4 is a simple fallback; neither requires probing separate
    /// audio/video tracks before the first frame can start.
    static func makeFastStartPlayerItem(_ detail: VideoDetail) -> AVPlayerItem? {
        guard let url = detail.playableURL else { return nil }
        return AVPlayerItem(url: url)
    }

    private static func composedItem(video videoURL: URL, audio audioURL: URL) async -> AVPlayerItem? {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
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
