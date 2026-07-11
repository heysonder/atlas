import Foundation
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func backupStoreRoundTripsSearchHistory() throws {
    let sourceContainer = try makeTestContainer()
    let source = sourceContainer.mainContext
    SearchHistoryStore.record("SwiftUI", in: source, now: Date(timeIntervalSince1970: 100))

    let backupURL = try BackupStore.export(from: source)
    let targetContainer = try makeTestContainer()
    let target = targetContainer.mainContext
    let summary = try BackupStore.restore(from: backupURL, into: target)
    let restored = try target.fetch(FetchDescriptor<SearchEntry>())

    #expect(summary.searches == 1)
    #expect(restored.count == 1)
    #expect(restored.first?.query == "swiftui")
    #expect(restored.first?.displayTitle == "SwiftUI")
}

@MainActor
@Test func compactNearLimitBackupRestoresAndReexportsWithinSameCeiling() throws {
    let backup = AtlasBackup(
        exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
        history: [
            .init(
                videoID: "video", title: "Compact", uploader: "Creator",
                thumbnailURL: nil, watchedAt: Date(timeIntervalSince1970: 1_700_000_001),
                positionSeconds: 10, durationSeconds: 60)
        ],
        searches: [],
        channels: [],
        playlists: [],
        feedback: [])
    let compact = try encodedBackupForTest(backup)
    let url = try writeBackupTestData(compact)
    let container = try makeTestContainer()
    let context = container.mainContext

    _ = try BackupStore.restore(
        from: url,
        into: context,
        maximumBytes: compact.count)
    let exportedURL = try BackupStore.export(from: context, maximumBytes: compact.count)
    let exported = try Data(contentsOf: exportedURL)

    #expect(exported.count <= compact.count)
    #expect(!exported.contains(0x0A))
}

@MainActor
@Test func backupStoreRestoresV1HistoryMissingResumeFields() throws {
    // v1 backups predate positionSeconds/durationSeconds on history rows; they
    // must decode with defaults instead of failing the whole import.
    let json = """
        {
          "version": 1,
          "exportedAt": "2026-06-01T00:00:00Z",
          "history": [
            {
              "videoID": "v1",
              "title": "Old Video",
              "uploader": "Creator",
              "watchedAt": "2026-05-01T00:00:00Z"
            }
          ],
          "channels": [],
          "playlists": [],
          "feedback": []
        }
        """.data(using: .utf8)!
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("atlas-backup-\(UUID().uuidString).json")
    try json.write(to: url)

    let targetContainer = try makeTestContainer()
    let target = targetContainer.mainContext
    let summary = try BackupStore.restore(from: url, into: target)
    let restored = try target.fetch(FetchDescriptor<HistoryEntry>())

    #expect(summary.history == 1)
    #expect(restored.first?.videoID == "v1")
    #expect(restored.first?.positionSeconds == 0)
    #expect(restored.first?.durationSeconds == 0)
}

@MainActor
@Test func backupStoreRestoresOlderBackupsWithoutSearchHistory() throws {
    let json = """
        {
          "version": 1,
          "exportedAt": "2026-06-01T00:00:00Z",
          "history": [],
          "channels": [],
          "playlists": [],
          "feedback": []
        }
        """.data(using: .utf8)!
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("atlas-backup-\(UUID().uuidString).json")
    try json.write(to: url)

    let targetContainer = try makeTestContainer()
    let target = targetContainer.mainContext
    let summary = try BackupStore.restore(from: url, into: target)

    #expect(summary.searches == 0)
}

@MainActor
@Test func liveWritesExportAndRestoreLosslessly() throws {
    let sourceContainer = try makeTestContainer()
    let source = sourceContainer.mainContext

    #expect(
        PlaybackHistoryStore.record(
            videoID: "video", title: "Video", uploader: "Creator",
            thumbnailURL: "https://cdn.example/thumb.jpg", in: source))
    #expect(
        PlaybackHistoryStore.savePosition(
            30, videoID: "video", duration: 120, in: source))
    #expect(SearchHistoryStore.record("SwiftUI", in: source) != nil)
    #expect(
        SubscriptionStore.setSubscribed(
            true, channelID: "channel", name: "Creator",
            avatarURL: "https://cdn.example/avatar.jpg", in: source))
    let playlist = try #require(PlaylistStore.createPlaylist(named: "Watch Later", in: source))
    #expect(
        PlaylistStore.add(
            PlaylistVideoSnapshot(
                videoID: "video", title: "Video", uploader: "Creator",
                thumbnailURL: "https://cdn.example/thumb.jpg", duration: 120),
            to: playlist, in: source) == .added)
    #expect(
        FeedbackStore.set(
            1, videoID: "video", title: "Video", uploader: "Creator",
            category: "Technology", tags: ["swift", "ios"], in: source))

    let backupURL = try BackupStore.export(from: source)
    defer { try? FileManager.default.removeItem(at: backupURL) }
    let targetContainer = try makeTestContainer()
    let target = targetContainer.mainContext
    let summary = try BackupStore.restore(from: backupURL, into: target)

    #expect(summary.history == 1)
    #expect(summary.searches == 1)
    #expect(summary.channels == 1)
    #expect(summary.playlists == 1)
    #expect(summary.feedback == 1)
    let history = try #require(target.fetch(FetchDescriptor<HistoryEntry>()).first)
    #expect(history.positionSeconds == 30)
    #expect(history.durationSeconds == 120)
    let restoredPlaylist = try #require(target.fetch(FetchDescriptor<Playlist>()).first)
    #expect(restoredPlaylist.name == "Watch Later")
    #expect(restoredPlaylist.videos.first?.videoID == "video")
    #expect(try target.fetch(FetchDescriptor<Feedback>()).first?.tags == ["swift", "ios"])
}

@MainActor
@Test func backupExportRejectsInvalidLegacyRowsWithActionableField() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    context.insert(
        HistoryEntry(
            videoID: "legacy", title: String(repeating: "x", count: 4_097)))

    #expect(
        throws: BackupExportError.storedLimitExceeded(
            field: "history[0].title",
            maximum: PersistedMetadataPolicy.maximumHumanTextBytes)
    ) {
        try BackupStore.export(from: context)
    }
}

@Test func backupExportEnforcesEncodedByteCeilingAtTheBoundary() throws {
    try BackupStore.requireExportSize(PersistedMetadataPolicy.maximumBackupBytes)
    #expect(
        throws: BackupExportError.encodedFileTooLarge(
            maximumBytes: PersistedMetadataPolicy.maximumBackupBytes)
    ) {
        try BackupStore.requireExportSize(PersistedMetadataPolicy.maximumBackupBytes + 1)
    }
}
