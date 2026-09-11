import Foundation
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func backupV3PreservesDistinctPlaylistsWithTheSameName() throws {
    let sourceContainer = try makeTestContainer()
    let source = sourceContainer.mainContext
    let first = Playlist(name: "Watch Later")
    let second = Playlist(name: "Watch Later")
    source.insert(first)
    source.insert(second)
    try source.save()

    let url = try BackupStore.export(from: source)
    defer { try? FileManager.default.removeItem(at: url) }
    let decoded = try BackupFileCodec.decode(Data(contentsOf: url))
    #expect(decoded.version == 3)
    #expect(Set(decoded.playlists.compactMap(\.id)) == Set([first.id, second.id]))

    let targetContainer = try makeTestContainer()
    let target = targetContainer.mainContext
    let summary = try BackupStore.restore(from: url, into: target)
    #expect(summary.playlists == 2)
    #expect(Set(try target.fetch(FetchDescriptor<Playlist>()).map(\.id)) == Set([first.id, second.id]))
    let repeated = try BackupStore.restore(from: url, into: target)
    #expect(repeated.playlists == 0)
}

@MainActor
@Test func backupV2MergesMissingMembershipIntoAnExistingPlaylist() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let existing = Playlist(name: "Watch Later")
    let existingVideo = PlaylistVideo(videoID: "existing", title: "Existing")
    existingVideo.playlist = existing
    context.insert(existing)
    context.insert(existingVideo)
    try context.save()

    var backup = playlistBackupForIdentityTests(name: "watch later", videoIDs: ["existing", "new"])
    backup.version = 2
    let url = try writeBackupTestData(try encodedBackupForTest(backup))
    defer { try? FileManager.default.removeItem(at: url) }
    let summary = try BackupStore.restore(from: url, into: context)

    let verification = ModelContext(container)
    let playlists = try verification.fetch(FetchDescriptor<Playlist>())
    #expect(summary.playlists == 1)
    #expect(playlists.count == 1)
    #expect(playlists.first?.id == existing.id)
    #expect(Set(playlists.first?.videos.map(\.videoID) ?? []) == Set(["existing", "new"]))
    let repeated = try BackupStore.restore(from: url, into: context)
    #expect(repeated.playlists == 0)
}

@MainActor
@Test func backupNameOnlyAmbiguityRejectsTheEntireRestore() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    context.insert(Playlist(name: "Trips"))
    context.insert(Playlist(name: "Trips"))
    try context.save()

    var backup = playlistBackupForIdentityTests(name: "Trips", videoIDs: ["new"])
    backup.version = 2
    backup.channels = [.init(channelID: "new-channel", name: "New", avatarURL: nil, subscribedAt: .now)]
    let url = try writeBackupTestData(try encodedBackupForTest(backup))
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: BackupRestoreError.ambiguousPlaylist(name: "Trips")) {
        try BackupStore.restore(from: url, into: context)
    }
    let verification = ModelContext(container)
    #expect(try verification.fetch(FetchDescriptor<Playlist>()).count == 2)
    #expect(try verification.fetch(FetchDescriptor<PlaylistVideo>()).isEmpty)
    #expect(try verification.fetch(FetchDescriptor<SubscribedChannel>()).isEmpty)
}

@MainActor
@Test func backupMembershipMergeChecksTheCombinedPlaylistLimit() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let existing = Playlist(name: "Trips")
    let video = PlaylistVideo(videoID: "existing", title: "Existing")
    video.playlist = existing
    context.insert(existing)
    context.insert(video)
    try context.save()
    let backup = playlistBackupForIdentityTests(name: "Trips", videoIDs: ["new"])
    let url = try writeBackupTestData(try encodedBackupForTest(backup))
    defer { try? FileManager.default.removeItem(at: url) }
    var limits = BackupStore.Limits()
    limits.maximumVideosPerPlaylist = 1

    #expect(throws: BackupRestoreError.limitExceeded(field: "playlists[0].videos", maximum: 1)) {
        try BackupStore.restore(from: url, into: context, limits: limits)
    }
    let verification = ModelContext(container)
    #expect(try verification.fetch(FetchDescriptor<PlaylistVideo>()).map(\.videoID) == ["existing"])
}

@MainActor
@Test func backupV3PreservesFavoritesSystemIdentity() throws {
    let sourceContainer = try makeTestContainer()
    let source = sourceContainer.mainContext
    let favorites = Playlist(
        id: PlaylistStore.favoritesPlaylistID, name: "Favorites",
        systemKind: PlaylistStore.favoritesSystemKind)
    source.insert(favorites)
    try source.save()
    let url = try BackupStore.export(from: source)
    defer { try? FileManager.default.removeItem(at: url) }
    let targetContainer = try makeTestContainer()
    let target = targetContainer.mainContext
    try BackupStore.restore(from: url, into: target)
    let restored = try #require(target.fetch(FetchDescriptor<Playlist>()).first)
    #expect(restored.id == PlaylistStore.favoritesPlaylistID)
    #expect(restored.systemKind == PlaylistStore.favoritesSystemKind)
}

@MainActor
@Test func backupRejectsUnknownSystemPlaylistKinds() throws {
    var backup = playlistBackupForIdentityTests(name: "Unknown", videoIDs: [])
    backup.playlists[0].systemKind = "unsupported"
    #expect(throws: BackupRestoreError.invalidValue(field: "playlists[0].systemKind")) {
        try BackupValidator.validate(backup)
    }
}

@MainActor
@Test func backupRestoreThenUIEditKeepsCausalCountersAndObservedStateFresh() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    #expect(SubscriptionStore.setSubscribed(true, channelID: "channel", name: "Creator", avatarURL: nil, in: context))
    #expect(SubscriptionStore.setSubscribed(false, channelID: "channel", name: "Creator", avatarURL: nil, in: context))
    let adapter = SyncStoreAdapter(context: context)
    // Hold the registered instances that a foreground sync coordinator would
    // already have read before opening the backup picker.
    let prefetchedEnrollment = try adapter.enrollment()
    let prefetchedState = try #require(try adapter.state(kind: .subscription, entityID: "channel"))
    let beforeImportCounter = prefetchedEnrollment.counter
    #expect(try SyncPayload.decode(SyncEnvelope.self, from: prefetchedState.envelopeData).isTombstone)

    var backup = playlistBackupForIdentityTests(name: "Restored", videoIDs: [])
    backup.channels = [.init(channelID: "channel", name: "Creator", avatarURL: nil, subscribedAt: .distantPast)]
    let url = try writeBackupTestData(try encodedBackupForTest(backup))
    defer { try? FileManager.default.removeItem(at: url) }
    try BackupStore.restore(from: url, into: context)

    let afterRestoreContext = ModelContext(container)
    let importedState = try #require(
        try SyncStoreAdapter(context: afterRestoreContext).state(kind: .subscription, entityID: "channel"))
    let importedEnvelope = try SyncPayload.decode(SyncEnvelope.self, from: importedState.envelopeData)
    let importedCounter = try SyncStoreAdapter(context: afterRestoreContext).enrollment().counter
    #expect(importedCounter > beforeImportCounter)
    #expect(!importedEnvelope.isTombstone)

    #expect(SubscriptionStore.setSubscribed(false, channelID: "channel", name: "Creator", avatarURL: nil, in: context))
    let verification = ModelContext(container)
    let finalAdapter = SyncStoreAdapter(context: verification)
    let finalState = try #require(try finalAdapter.state(kind: .subscription, entityID: "channel"))
    let finalEnvelope = try SyncPayload.decode(SyncEnvelope.self, from: finalState.envelopeData)
    #expect(try finalAdapter.enrollment().counter > importedCounter)
    #expect(finalEnvelope.isTombstone)
    #expect(try SyncMergePolicy.merge(importedEnvelope, finalEnvelope) == finalEnvelope)
}

@MainActor
@Test func backupPreflightFailureKeepsPendingLocalChanges() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let pending = HistoryEntry(videoID: "pending", title: "Unsaved local work")
    context.insert(pending)
    var backup = playlistBackupForIdentityTests(name: "Trips", videoIDs: [])
    backup.history = [
        .init(
            videoID: "imported", title: "Imported", uploader: nil, thumbnailURL: nil,
            watchedAt: .now, positionSeconds: 0, durationSeconds: 0)
    ]
    let url = try writeBackupTestData(try encodedBackupForTest(backup))
    defer { try? FileManager.default.removeItem(at: url) }
    var limits = BackupStore.Limits()
    limits.maximumHistory = 1

    #expect(throws: BackupRestoreError.limitExceeded(field: "history", maximum: 1)) {
        try BackupStore.restore(from: url, into: context, limits: limits)
    }
    #expect(context.hasChanges)
    #expect(try context.fetch(FetchDescriptor<HistoryEntry>()).map(\.videoID) == ["pending"])
    #expect(try ModelContext(container).fetch(FetchDescriptor<HistoryEntry>()).isEmpty)
}

@MainActor
@Test func backupRestoringDeletedPlaylistsStartsAFreshMembershipIncarnation() throws {
    for name in ["Favorites", "Trips"] {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = try #require(PlaylistStore.createPlaylist(named: name, in: context))
        let id = playlist.id
        #expect(
            PlaylistStore.add(
                PlaylistVideoSnapshot(videoID: "saved", title: "Saved", uploader: nil, thumbnailURL: nil, duration: 60),
                to: playlist, in: context) == .added)
        let backupURL = try BackupStore.export(from: context)
        defer { try? FileManager.default.removeItem(at: backupURL) }
        #expect(PlaylistStore.delete(playlist, in: context))

        try BackupStore.restore(from: backupURL, into: context)
        let restored = try #require(PlaylistStore.playlist(id: id, in: context))
        #expect(restored.id == id)
        #expect(restored.syncIncarnation != nil)
        #expect(restored.videos.map(\.videoID) == ["saved"])
    }
}

@MainActor
private func playlistBackupForIdentityTests(name: String, videoIDs: [String]) -> AtlasBackup {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return AtlasBackup(
        exportedAt: date, history: [], searches: [], channels: [],
        playlists: [
            .init(
                name: name, createdAt: date,
                videos: videoIDs.map {
                    .init(videoID: $0, title: $0, uploader: nil, thumbnailURL: nil, duration: 60, addedAt: date)
                })
        ],
        feedback: [])
}
