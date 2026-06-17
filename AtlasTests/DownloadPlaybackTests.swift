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

@Test func streamPlaybackPrefersDirectSourceBeforeComposedUpgrade() throws {
    let detail = VideoDetail(
        title: "Fast Start",
        description: nil,
        uploader: nil,
        uploaderUrl: nil,
        uploaderAvatar: nil,
        thumbnailUrl: nil,
        hls: "https://example.com/master.m3u8",
        duration: 120,
        views: nil,
        likes: nil,
        uploaded: nil,
        uploaderVerified: nil,
        uploaderSubscriberCount: nil,
        creators: nil,
        livestream: nil,
        chapters: nil,
        videoStreams: [
            Stream(
                url: "https://example.com/1080.mp4",
                format: "MP4",
                quality: "1080p",
                mimeType: "video/mp4",
                codec: "avc1.640028",
                videoOnly: true,
                bitrate: nil,
                width: 1920,
                height: 1080,
                fps: 30)
        ],
        audioStreams: [
            Stream(
                url: "https://example.com/audio.m4a",
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
        ],
        subtitles: nil,
        relatedStreams: nil,
        category: nil,
        tags: nil)

    let source = try #require(StreamPlaybackBuilder.preferredSource(
        detail,
        allowAV1: false,
        preferredLanguages: ["en-US"]))

    #expect(source == .direct(URL(string: "https://example.com/master.m3u8")!))
}
