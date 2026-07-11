import Foundation
import PipedKit
import Testing

@testable import Atlas

@MainActor
@Test func downloadReconciliationFailsClosedWithoutPersistentInventory() {
    var fetchCalled = false
    let recovery = DownloadManager.reconciliationFileNames(
        canReconcilePersistentDownloads: false,
        fetch: {
            fetchCalled = true
            return []
        })
    #expect(recovery == nil)
    #expect(!fetchCalled)

    let failedFetch = DownloadManager.reconciliationFileNames(
        canReconcilePersistentDownloads: true,
        fetch: { throw CocoaError(.fileReadCorruptFile) })
    #expect(failedFetch == nil)

    let claimed = DownloadManager.reconciliationFileNames(
        canReconcilePersistentDownloads: true,
        fetch: {
            ["safeID.mp4", "safeID.thumb", "safeID.captions.vtt", "../escape.mp4"]
        }
    )
    #expect(claimed == ["safeID.mp4", "safeID.thumb", "safeID.captions.vtt"])
}

@MainActor
@Test func downloadReconciliationDeletesOnlyKnownUnclaimedArtifacts() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("atlas-download-reconcile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fileNames = [
        "claimed.mp4",
        "claimed.thumb",
        "claimed.captions.vtt",
        "orphan.mp4",
        "orphan.thumb",
        "orphan.captions.ttml",
        "merge.video.mp4",
        "merge.audio.m4a",
        "notes.txt",
    ]
    for name in fileNames {
        try Data(name.utf8).write(to: root.appendingPathComponent(name))
    }
    DownloadStore.removeOrphanedFiles(
        claimedFileNames: ["claimed.mp4", "claimed.thumb", "claimed.captions.vtt"],
        in: root
    )

    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("claimed.mp4").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("claimed.thumb").path))
    #expect(
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent("claimed.captions.vtt").path
        ))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan.mp4").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan.thumb").path))
    #expect(
        !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("orphan.captions.ttml").path
        ))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("merge.video.mp4").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("merge.audio.m4a").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes.txt").path))
}

@MainActor
@Test func recoveryDownloadManagerDoesNotStartOrOverwriteDownloads() throws {
    let container = try makeTestContainer()
    let manager = DownloadManager(
        modelContext: container.mainContext,
        storageMode: .recoveryReadOnly)
    let app = AppModel(
        instanceStore: InstanceStore(
            defaults: makeTestDefaults(), secureStore: MemoryInstanceSecureStore()))
    let output = try DownloadStore.fileURL(videoID: "safeID", artifact: .media)
    try Data("preserve".utf8).write(to: output, options: .atomic)
    defer { try? FileManager.default.removeItem(at: output) }

    manager.download(
        videoID: "safeID", title: "Preserve", uploader: nil, thumbnail: nil, using: app)

    #expect(manager.active.isEmpty)
    #expect(try Data(contentsOf: output) == Data("preserve".utf8))
}

@MainActor
@Test func downloadManagerRejectsHostileVideoIdentifierBeforeStartingTask() throws {
    let container = try makeTestContainer()
    let manager = DownloadManager(
        modelContext: container.mainContext,
        storageMode: .persistent,
        reconcileOnInit: false)
    let app = AppModel(
        instanceStore: InstanceStore(
            defaults: makeTestDefaults(), secureStore: MemoryInstanceSecureStore()))

    manager.download(
        videoID: "../escape", title: "Escape", uploader: nil, thumbnail: nil, using: app)

    #expect(manager.active.isEmpty)
}

@MainActor
@Test func cancelledDownloadKeepsOwnershipUntilItsTaskUnwinds() throws {
    let container = try makeTestContainer()
    let manager = DownloadManager(
        modelContext: container.mainContext,
        storageMode: .persistent,
        reconcileOnInit: false)
    let app = AppModel(
        instanceStore: InstanceStore(
            defaults: makeTestDefaults(),
            secureStore: MemoryInstanceSecureStore()
        ))

    manager.download(
        videoID: "cancelRace",
        title: "Original",
        uploader: nil,
        thumbnail: nil,
        using: app
    )
    #expect(manager.active["cancelRace"]?.title == "Original")

    manager.cancel("cancelRace")
    manager.download(
        videoID: "cancelRace",
        title: "Replacement",
        uploader: nil,
        thumbnail: nil,
        using: app
    )

    #expect(manager.active["cancelRace"] == nil)
}

@MainActor
@Test func downloadWaitsForStartupReconciliationBeforeResolvingStreams() async throws {
    let container = try makeTestContainer()
    let reconciliation = DownloadReconciliationGate()
    let resolver = DownloadResolverProbe()
    let manager = DownloadManager(
        modelContext: container.mainContext,
        storageMode: .persistent,
        reconciler: { _ in await reconciliation.waitForRelease() })
    let app = AppModel(
        instanceStore: InstanceStore(
            defaults: makeTestDefaults(),
            secureStore: MemoryInstanceSecureStore(value: "https://example.com")),
        streamResolver: { _, _ in try await resolver.resolve() })

    await reconciliation.waitUntilStarted()
    manager.download(
        videoID: "startupRace",
        title: "Startup race",
        uploader: nil,
        thumbnail: nil,
        using: app)
    for _ in 0..<10 { await Task.yield() }
    #expect(await resolver.callCount == 0)

    await reconciliation.release()
    await resolver.waitUntilCalled()
    #expect(await resolver.callCount == 1)
}

private actor DownloadReconciliationGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor DownloadResolverProbe {
    private(set) var callCount = 0

    func resolve() throws -> VideoDetail {
        callCount += 1
        throw DownloadResolverProbeError.expected
    }

    func waitUntilCalled() async {
        while callCount == 0 { await Task.yield() }
    }
}

private enum DownloadResolverProbeError: Error {
    case expected
}
