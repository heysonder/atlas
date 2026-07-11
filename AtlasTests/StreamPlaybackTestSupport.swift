import Foundation
import PipedKit

func streamPlaybackDetail(
    hls: String? = "https://example.com/master.m3u8",
    includeComposedStreams: Bool = true,
    videoURL: String = "https://example.com/1080.mp4",
    audioURL: String = "https://example.com/audio.m4a",
    av1StreamURL: String? = nil,
    av1StreamHeight: Int? = 2160,
    progressiveURL: String? = nil,
    vp9StreamHeight: Int? = nil
) -> VideoDetail {
    var videoStreams: [PipedKit.MediaStream] = []
    if includeComposedStreams {
        videoStreams.append(
            MediaStream(
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
        videoStreams.append(
            MediaStream(
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
        videoStreams.append(
            MediaStream(
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
        videoStreams.append(
            MediaStream(
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
        uploaderURL: nil,
        uploaderAvatar: nil,
        thumbnailURL: nil,
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
        audioStreams: includeComposedStreams
            ? [
                MediaStream(
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
