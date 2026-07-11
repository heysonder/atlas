import Foundation
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func backupRestoreRejectsPostMergePerKindLimitWithoutMutation() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    context.insert(HistoryEntry(videoID: "existing", title: "Existing"))
    try context.save()

    let backup = AtlasBackup(
        exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
        history: [
            .init(
                videoID: "imported", title: "Imported", uploader: nil,
                thumbnailURL: nil, watchedAt: Date(timeIntervalSince1970: 1_700_000_001),
                positionSeconds: 0, durationSeconds: 0)
        ],
        searches: [],
        channels: [],
        playlists: [],
        feedback: [])
    let url = try writeBackupTestData(try encodedBackupForTest(backup))
    var limits = BackupStore.Limits()
    limits.maximumHistory = 1

    #expect(throws: BackupRestoreError.limitExceeded(field: "history", maximum: 1)) {
        try BackupStore.restore(from: url, into: context, limits: limits)
    }
    let stored = try context.fetch(FetchDescriptor<HistoryEntry>())
    #expect(stored.map(\.videoID) == ["existing"])
}

@MainActor
@Test func backupRestoreRejectsPostMergePlaylistVideoAndAggregateLimits() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let existing = Playlist(name: "Existing")
    let existingVideo = PlaylistVideo(videoID: "existing-video", title: "Existing")
    existingVideo.playlist = existing
    context.insert(existing)
    context.insert(existingVideo)
    try context.save()

    let backup = AtlasBackup(
        exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
        history: [],
        searches: [],
        channels: [],
        playlists: [
            .init(
                name: "Imported",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                videos: [
                    .init(
                        videoID: "imported-video", title: "Imported", uploader: nil,
                        thumbnailURL: nil, duration: 60,
                        addedAt: Date(timeIntervalSince1970: 1_700_000_000))
                ])
        ],
        feedback: [])
    let url = try writeBackupTestData(try encodedBackupForTest(backup))

    var playlistLimits = BackupStore.Limits()
    playlistLimits.maximumPlaylistVideos = 1
    #expect(
        throws: BackupRestoreError.limitExceeded(
            field: "playlists.videos", maximum: 1)
    ) {
        try BackupStore.restore(from: url, into: context, limits: playlistLimits)
    }

    var aggregateLimits = BackupStore.Limits()
    aggregateLimits.maximumTotalRecords = 2
    #expect(throws: BackupRestoreError.limitExceeded(field: "records", maximum: 2)) {
        try BackupStore.restore(from: url, into: context, limits: aggregateLimits)
    }
    #expect(try context.fetch(FetchDescriptor<Playlist>()).map(\.name) == ["Existing"])
    #expect(try context.fetch(FetchDescriptor<PlaylistVideo>()).map(\.videoID) == ["existing-video"])
}

@MainActor
@Test func backupStoreRejectsInvalidSearchCountsWithoutMutation() throws {
    let json = """
        {
          "version": 2,
          "exportedAt": "2026-06-01T00:00:00Z",
          "history": [],
          "searches": [
            {
              "query": "swiftui",
              "displayQuery": "SwiftUI",
              "lastSearchedAt": "2026-06-01T00:00:00Z",
              "count": 0
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
    #expect(throws: BackupRestoreError.invalidValue(field: "searches[0].count")) {
        try BackupStore.restore(from: url, into: target)
    }
    let restored = try target.fetch(FetchDescriptor<SearchEntry>())

    #expect(restored.isEmpty)
}

@MainActor
@Test func backupStoreRejectsSparseFileOverSizeLimitBeforeMutation() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("atlas-backup-oversize-\(UUID().uuidString).json")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(BackupStore.maximumImportBytes + 1))
    try handle.close()
    defer { try? FileManager.default.removeItem(at: url) }

    let container = try makeTestContainer()
    let target = container.mainContext
    #expect(
        throws: BackupRestoreError.fileTooLarge(
            maximumBytes: BackupStore.maximumImportBytes)
    ) {
        try BackupStore.restore(from: url, into: target)
    }
    #expect(try target.fetch(FetchDescriptor<HistoryEntry>()).isEmpty)
}

@MainActor
@Test func backupStoreRejectsUnsupportedVersionBeforeMutation() throws {
    let json = """
        {
          "version": 999,
          "exportedAt": "2026-06-01T00:00:00Z",
          "history": [], "searches": [], "channels": [], "playlists": [], "feedback": []
        }
        """.data(using: .utf8)!
    let url = try writeBackupTestData(json)
    defer { try? FileManager.default.removeItem(at: url) }
    let container = try makeTestContainer()
    let target = container.mainContext

    #expect(throws: BackupRestoreError.unsupportedVersion(999)) {
        try BackupStore.restore(from: url, into: target)
    }
    #expect(try target.fetch(FetchDescriptor<HistoryEntry>()).isEmpty)
}

@MainActor
@Test func backupStoreValidatesEntireBackupBeforeInsertingEarlyRows() throws {
    let json = """
        {
          "version": 2,
          "exportedAt": "2026-06-01T00:00:00Z",
          "history": [{
            "videoID": "validID", "title": "Would otherwise import",
            "watchedAt": "2026-05-01T00:00:00Z", "positionSeconds": 10,
            "durationSeconds": 100
          }],
          "searches": [], "channels": [], "playlists": [],
          "feedback": [{
            "videoID": "invalidSignal", "signal": 2, "title": "Invalid",
            "createdAt": "2026-05-01T00:00:00Z"
          }]
        }
        """.data(using: .utf8)!
    let url = try writeBackupTestData(json)
    defer { try? FileManager.default.removeItem(at: url) }
    let container = try makeTestContainer()
    let target = container.mainContext
    target.insert(HistoryEntry(videoID: "existing", title: "Existing"))
    try target.save()

    #expect(throws: BackupRestoreError.invalidValue(field: "feedback[0].signal")) {
        try BackupStore.restore(from: url, into: target)
    }
    let rows = try target.fetch(FetchDescriptor<HistoryEntry>())
    #expect(rows.map(\.videoID) == ["existing"])
}

@MainActor
@Test func backupStoreRejectsHugeAndNegativePlaybackNumbers() throws {
    for (value, field) in [("1e300", "positionSeconds"), ("-1", "durationSeconds")] {
        let json = """
            {
              "version": 2,
              "exportedAt": "2026-06-01T00:00:00Z",
              "history": [{
                "videoID": "validID", "title": "Invalid number",
                "watchedAt": "2026-05-01T00:00:00Z",
                "positionSeconds": \(field == "positionSeconds" ? value : "0"),
                "durationSeconds": \(field == "durationSeconds" ? value : "100")
              }],
              "searches": [], "channels": [], "playlists": [], "feedback": []
            }
            """.data(using: .utf8)!
        let url = try writeBackupTestData(json)
        defer { try? FileManager.default.removeItem(at: url) }
        let container = try makeTestContainer()
        let target = container.mainContext

        #expect(throws: BackupRestoreError.invalidValue(field: "history[0].\(field)")) {
            try BackupStore.restore(from: url, into: target)
        }
        #expect(try target.fetch(FetchDescriptor<HistoryEntry>()).isEmpty)
    }
}

@MainActor
@Test func backupStoreRejectsDuplicateUniqueKeysBeforeMutation() throws {
    let json = """
        {
          "version": 2,
          "exportedAt": "2026-06-01T00:00:00Z",
          "history": [
            {"videoID":"same", "title":"One", "watchedAt":"2026-05-01T00:00:00Z", "positionSeconds":0, "durationSeconds":0},
            {"videoID":"same", "title":"Two", "watchedAt":"2026-05-02T00:00:00Z", "positionSeconds":0, "durationSeconds":0}
          ],
          "searches": [], "channels": [], "playlists": [], "feedback": []
        }
        """.data(using: .utf8)!
    let url = try writeBackupTestData(json)
    defer { try? FileManager.default.removeItem(at: url) }
    let container = try makeTestContainer()
    let target = container.mainContext

    #expect(throws: BackupRestoreError.duplicateValue(field: "history[1].videoID")) {
        try BackupStore.restore(from: url, into: target)
    }
    #expect(try target.fetch(FetchDescriptor<HistoryEntry>()).isEmpty)
}
