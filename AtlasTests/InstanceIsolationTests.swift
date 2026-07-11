import Foundation
import PipedKit
import Testing

@testable import Atlas

@MainActor
@Test func instanceSwitchRejectsLateResultsAndPreservesNewCache() async throws {
    let resolver = ControlledStreamResolver()
    let app = makeInstanceIsolationApp(initialURL: "https://a.example", resolver: resolver)

    let oldTask = Task { try await app.resolveStream("sameVideo") }
    await resolver.waitForCall(instance: "a.example", videoID: "sameVideo")

    app.instanceURLString = "https://b.example"
    let newTask = Task { try await app.resolveStream("sameVideo") }
    await resolver.waitForCall(instance: "b.example", videoID: "sameVideo")

    await resolver.complete(
        instance: "b.example", videoID: "sameVideo", detail: testVideoDetail(title: "B"))
    #expect(try await newTask.value.title == "B")

    await resolver.complete(
        instance: "a.example", videoID: "sameVideo", detail: testVideoDetail(title: "A"))
    do {
        _ = try await oldTask.value
        Issue.record("The cancelled old-instance request unexpectedly succeeded.")
    } catch is CancellationError {
        // Expected: the controlled resolver deliberately returned after cancellation.
    } catch {
        Issue.record("Expected CancellationError, received \(error).")
    }

    #expect(try await app.resolveStream("sameVideo").title == "B")
    #expect(await resolver.callCount(instance: "b.example", videoID: "sameVideo") == 1)
}

@MainActor
@Test func assigningSameInstancePreservesGenerationAndCache() async throws {
    let resolver = ControlledStreamResolver()
    let app = makeInstanceIsolationApp(initialURL: "https://same.example", resolver: resolver)

    let firstTask = Task { try await app.resolveStream("video") }
    await resolver.waitForCall(instance: "same.example", videoID: "video")
    await resolver.complete(
        instance: "same.example", videoID: "video", detail: testVideoDetail(title: "Cached"))
    _ = try await firstTask.value
    let generation = app.instanceGeneration

    app.instanceURLString = "https://same.example"

    #expect(app.instanceGeneration == generation)
    #expect(try await app.resolveStream("video").title == "Cached")
    #expect(await resolver.callCount(instance: "same.example", videoID: "video") == 1)
}

@MainActor
@Test func throttledCallerRejectsLateSharedResultAfterInstanceSwitch() async throws {
    let resolver = ControlledStreamResolver()
    let app = makeInstanceIsolationApp(initialURL: "https://a.example", resolver: resolver)

    let regular = Task { try await app.resolveStream("shared-video") }
    await resolver.waitForCall(instance: "a.example", videoID: "shared-video")
    let throttled = Task { try await app.resolveStreamThrottled("shared-video") }
    for _ in 0..<10 { await Task.yield() }
    #expect(await resolver.callCount(instance: "a.example", videoID: "shared-video") == 1)

    app.instanceURLString = "https://b.example"
    await resolver.complete(
        instance: "a.example",
        videoID: "shared-video",
        detail: testVideoDetail(title: "Stale A"))

    await expectCancellation(of: regular)
    await expectCancellation(of: throttled)
    #expect(await resolver.callCount(instance: "b.example", videoID: "shared-video") == 0)
}

@MainActor
@Test func cancelledThrottleWaiterNeverStartsAStreamRequest() async throws {
    let resolver = ControlledStreamResolver()
    let app = makeInstanceIsolationApp(initialURL: "https://a.example", resolver: resolver)

    let startGate = InstanceIsolationStartGate()
    let cancelledBeforeAcquire = Task {
        await startGate.waitForRelease()
        return try await app.resolveStreamThrottled("cancelled-before-acquire")
    }
    await startGate.waitUntilStarted()
    cancelledBeforeAcquire.cancel()
    await startGate.release()
    await expectCancellation(of: cancelledBeforeAcquire)
    #expect(
        await resolver.callCount(
            instance: "a.example", videoID: "cancelled-before-acquire") == 0)

    let first = Task { try await app.resolveStreamThrottled("first") }
    let second = Task { try await app.resolveStreamThrottled("second") }
    await resolver.waitForCall(instance: "a.example", videoID: "first")
    await resolver.waitForCall(instance: "a.example", videoID: "second")

    let cancelled = Task { try await app.resolveStreamThrottled("cancelled") }
    for _ in 0..<10 { await Task.yield() }
    #expect(await resolver.callCount(instance: "a.example", videoID: "cancelled") == 0)
    cancelled.cancel()
    await expectCancellation(of: cancelled)

    await resolver.complete(
        instance: "a.example", videoID: "first", detail: testVideoDetail(title: "First"))
    #expect(try await first.value.title == "First")
    for _ in 0..<10 { await Task.yield() }
    #expect(await resolver.callCount(instance: "a.example", videoID: "cancelled") == 0)

    await resolver.complete(
        instance: "a.example", videoID: "second", detail: testVideoDetail(title: "Second"))
    #expect(try await second.value.title == "Second")
}

private actor InstanceIsolationStartGate {
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

private actor ControlledStreamResolver {
    private struct Key: Hashable {
        let instance: String
        let videoID: String
    }

    private var calls: [Key: Int] = [:]
    private var continuations: [Key: [CheckedContinuation<VideoDetail, Error>]] = [:]

    func resolve(client: PipedClient, videoID: String) async throws -> VideoDetail {
        let key = Key(instance: client.baseURL.host ?? "", videoID: videoID)
        calls[key, default: 0] += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[key, default: []].append(continuation)
        }
    }

    func complete(instance: String, videoID: String, detail: VideoDetail) {
        let key = Key(instance: instance, videoID: videoID)
        guard var pending = continuations[key], !pending.isEmpty else {
            Issue.record("No controlled request was pending for \(instance)/\(videoID).")
            return
        }
        let continuation = pending.removeFirst()
        continuations[key] = pending
        continuation.resume(returning: detail)
    }

    func callCount(instance: String, videoID: String) -> Int {
        calls[Key(instance: instance, videoID: videoID), default: 0]
    }

    func waitForCall(instance: String, videoID: String) async {
        let key = Key(instance: instance, videoID: videoID)
        while calls[key, default: 0] == 0 {
            await Task.yield()
        }
    }
}

@MainActor
private func makeInstanceIsolationApp(
    initialURL: String,
    resolver: ControlledStreamResolver
) -> AppModel {
    let suiteName = "atlas.instance-isolation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let secureStore = InstanceIsolationSecureStore(value: initialURL)
    let store = InstanceStore(defaults: defaults, secureStore: secureStore)
    return AppModel(
        instanceStore: store,
        streamResolver: { client, videoID in
            try await resolver.resolve(client: client, videoID: videoID)
        })
}

private final class InstanceIsolationSecureStore: InstanceSecureStoring {
    var value: String?

    init(value: String?) {
        self.value = value
    }

    func loadInstanceURL() -> String? { value }
    func saveInstanceURL(_ value: String) { self.value = value }
    func clearInstanceURL() { value = nil }
}

@MainActor
private func expectCancellation(of task: Task<VideoDetail, Error>) async {
    do {
        _ = try await task.value
        Issue.record("The cancelled old-instance request unexpectedly succeeded.")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("Expected CancellationError, received \(error).")
    }
}

private func testVideoDetail(title: String) -> VideoDetail {
    VideoDetail(
        title: title,
        description: nil,
        uploader: nil,
        uploaderURL: nil,
        uploaderAvatar: nil,
        thumbnailURL: nil,
        hls: nil,
        duration: nil,
        views: nil,
        likes: nil,
        uploaded: nil,
        uploaderVerified: nil,
        uploaderSubscriberCount: nil,
        creators: nil,
        livestream: nil,
        chapters: nil,
        videoStreams: nil,
        audioStreams: nil,
        subtitles: nil,
        relatedStreams: nil,
        category: nil,
        tags: nil)
}
