import Testing

@testable import Atlas

@MainActor
@Test func downloadedVideoRejectsWrongRoleAndTraversalFileNames() {
    let wrongRole = DownloadedVideo(
        videoID: "safeID", title: "Wrong role", fileName: "safeID.thumb",
        thumbnailFileName: "safeID.mp4", captionFileName: "safeID.mp4")
    #expect(wrongRole.fileURL == nil)
    #expect(wrongRole.thumbnailURL == nil)
    #expect(wrongRole.captionURL == nil)

    let traversal = DownloadedVideo(
        videoID: "safeID", title: "Traversal", fileName: "../outside.mp4",
        thumbnailFileName: "/tmp/outside.thumb", captionFileName: "..\\outside.captions.vtt")
    #expect(traversal.fileURL == nil)
    #expect(traversal.thumbnailURL == nil)
    #expect(traversal.captionURL == nil)
}
