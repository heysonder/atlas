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
