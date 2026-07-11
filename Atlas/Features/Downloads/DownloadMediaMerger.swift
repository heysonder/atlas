import AVFoundation
import Foundation

nonisolated extension DownloadStore {
    /// Merges separate video and audio tracks into an MP4 without re-encoding.
    static func mergeToMP4(video: URL, audio: URL, output: URL) async throws {
        guard contains(video), contains(audio), contains(output) else {
            throw StoreError.invalidFileName
        }

        let videoAsset = AVURLAsset(
            url: video,
            options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"]
        )
        let audioAsset = AVURLAsset(
            url: audio,
            options: [AVURLAssetOverrideMIMETypeKey: "audio/mp4"]
        )
        let composition = AVMutableComposition()

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
            let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
            let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ),
            let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw StoreError.noTracks
        }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )
        try compositionAudioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: min(videoDuration, audioDuration)),
            of: audioTrack,
            at: .zero
        )

        guard
            let export = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetPassthrough
            )
        else {
            throw StoreError.exportUnavailable
        }
        try? FileManager.default.removeItem(at: output)
        do {
            try await export.export(to: output, as: .mp4)
        } catch {
            throw StoreError.exportFailed(error.localizedDescription)
        }
    }
}
