import Foundation
import Testing

@testable import Atlas

@Test func thumbnailSidecarWriterRejectsInvalidImagesBeforeWriting() throws {
    let destination = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("jpg")

    #expect(!DownloadSidecarWriter.writeThumbnail(Data("not an image".utf8), to: destination))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func thumbnailSidecarWriterAtomicallyWritesValidatedImages() throws {
    let destination = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("png")
    defer { try? FileManager.default.removeItem(at: destination) }
    let imageData = try #require(
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))

    #expect(DownloadSidecarWriter.writeThumbnail(imageData, to: destination))
    #expect(try Data(contentsOf: destination) == imageData)
}
