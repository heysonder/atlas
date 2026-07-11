import Foundation
import Testing

@testable import Atlas

@MainActor
@Test func addToQueueAtEndIsAvailableOnlyAfterQueueHasItems() {
    let app = makeQueueTestApp()
    let first = PlayRequest(videoID: "first", title: "First")
    let second = PlayRequest(videoID: "second", title: "Second")

    #expect(!app.canAddToQueueAtEnd)

    app.playNext(first)

    #expect(app.canAddToQueueAtEnd)
    #expect(app.queuedVideos.map(\.request.videoID) == ["first"])

    app.addToQueue(second)
    app.addToQueue(first)

    #expect(app.queuedVideos.map(\.request.videoID) == ["first", "second", "first"])

    app.clearQueue()

    #expect(!app.canAddToQueueAtEnd)
}

private func makeQueueTestApp() -> AppModel {
    let suiteName = "atlas.queue.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let instanceStore = InstanceStore(defaults: defaults, secureStore: QueueMemoryInstanceSecureStore())
    return AppModel(instanceStore: instanceStore)
}

private final class QueueMemoryInstanceSecureStore: InstanceSecureStoring {
    func loadInstanceURL() -> String? {
        nil
    }

    func saveInstanceURL(_ value: String) {}

    func clearInstanceURL() {}
}
