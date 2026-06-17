import AVFoundation
import CoreMedia
import PipedKit

enum StreamPlaybackBuilder {
    enum PlaybackSource: Equatable {
        case direct(URL)
        case composed(video: URL, audio: URL)
    }

    /// Builds the fastest playable item first. Direct HLS/progressive playback
    /// lets AVPlayer start buffering immediately; composing separate video/audio
    /// tracks is kept only for videos that expose no direct playable URL.
    static func makePlayerItem(
        _ detail: VideoDetail,
        allowAV1: Bool,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) async -> (item: AVPlayerItem, composed: Bool)? {
        switch preferredSource(detail, allowAV1: allowAV1, preferredLanguages: preferredLanguages) {
        case .direct(let url):
            return (AVPlayerItem(url: url), false)
        case .composed(let video, let audio):
            guard let composed = await composedItem(video: video, audio: audio) else { return nil }
            return (composed, true)
        case nil:
            return nil
        }
    }

    static func preferredSource(
        _ detail: VideoDetail,
        allowAV1: Bool,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> PlaybackSource? {
        if let url = detail.playableURL { return .direct(url) }
        guard let source = detail.bestComposedSource(
            allowAV1: allowAV1,
            preferredLanguages: preferredLanguages
        ) else {
            return nil
        }
        return .composed(video: source.video, audio: source.audio)
    }

    static func fallbackPlayerItem(for detail: VideoDetail) -> AVPlayerItem? {
        makeFastStartPlayerItem(detail)
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
