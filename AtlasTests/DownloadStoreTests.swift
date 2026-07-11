import Foundation
import Testing

@testable import Atlas

@Test func downloadStoreFlagsEveryRecognizedUnclaimedArtifactAsOrphaned() {
    let files = [
        "aaaaaaaaaaa.mp4",
        "aaaaaaaaaaa.thumb",
        "aaaaaaaaaaa.captions.vtt",
        "bbbbbbbbbbb.mp4",
        "ccccccccccc.video.mp4",
        "ccccccccccc.audio.m4a",
        "ddddddddddd.thumb",
        "ddddddddddd.captions.ttml",
    ]

    let orphans = DownloadStore.orphanedFileNames(
        in: files,
        claimedFileNames: [
            "aaaaaaaaaaa.mp4",
            "aaaaaaaaaaa.thumb",
            "aaaaaaaaaaa.captions.vtt",
        ]
    )

    #expect(
        Set(orphans) == [
            "bbbbbbbbbbb.mp4",
            "ccccccccccc.video.mp4",
            "ccccccccccc.audio.m4a",
            "ddddddddddd.thumb",
            "ddddddddddd.captions.ttml",
        ])
}

@Test func downloadStoreNeverFlagsClaimedFileNames() {
    let claimed: Set<String> = [
        "aaaaaaaaaaa.mp4",
        "aaaaaaaaaaa.thumb",
        "bbbbbbbbbbb.mp4",
    ]

    let orphans = DownloadStore.orphanedFileNames(
        in: ["aaaaaaaaaaa.mp4", "bbbbbbbbbbb.mp4", "aaaaaaaaaaa.thumb", "notes.txt"],
        claimedFileNames: claimed)

    #expect(orphans.isEmpty)
}

@Test func downloadStoreAcceptsOnlySafeVideoIdentifiers() {
    let valid = ["abc", "dQw4w9WgXcQ", "video_ID-123", String(repeating: "a", count: 128)]
    for videoID in valid {
        #expect(DownloadStore.isValidVideoID(videoID))
    }

    let invalid = [
        "", ".", "..", "../escape", "a/../../escape", "a\\escape",
        "/absolute", "%2E%2E%2Fescape", "has space", "café",
        String(repeating: "a", count: 129),
    ]
    for videoID in invalid {
        #expect(!DownloadStore.isValidVideoID(videoID))
    }
}

@Test func downloadStoreResolvesEveryArtifactInsideItsRoot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("atlas-download-root-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let artifacts: [DownloadStore.Artifact] = [
        .media, .videoTemporary, .audioTemporary, .thumbnail, .captionVTT, .captionTTML,
    ]
    for artifact in artifacts {
        let name = try DownloadStore.fileName(videoID: "safe_ID-1", artifact: artifact)
        let url = try #require(DownloadStore.fileURL(name, expected: [artifact], in: root))
        #expect(url.deletingLastPathComponent() == root.standardizedFileURL)
    }
}

@Test func downloadStoreRejectsSymlinkArtifacts() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("atlas-download-symlink-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("Downloads", isDirectory: true)
    let outside = base.appendingPathComponent("outside.mp4")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("sentinel".utf8).write(to: outside)
    let link = root.appendingPathComponent("safeID.mp4")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    defer { try? FileManager.default.removeItem(at: base) }

    #expect(DownloadStore.fileURL("safeID.mp4", expected: [.media], in: root) == nil)
    #expect(!DownloadStore.contains(link, in: root))
    #expect(try Data(contentsOf: outside) == Data("sentinel".utf8))
}
