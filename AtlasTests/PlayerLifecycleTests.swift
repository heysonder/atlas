import AVKit
import Foundation
import PipedKit
import Testing

@testable import Atlas

@MainActor
@Suite(.serialized)
struct PlayerLifecycleTests {
    private func makeCoordinator() throws -> VideoPlayerPresenter.Coordinator {
        let container = try makeTestContainer()
        let app = AppModel(
            instanceStore: InstanceStore(defaults: makeTestDefaults(), secureStore: MemoryInstanceSecureStore()))
        return VideoPlayerPresenter.Coordinator(
            app: app,
            downloads: DownloadManager(modelContext: container.mainContext, storageMode: .recoveryReadOnly),
            modelContext: container.mainContext,
            clearRequest: {})
    }

    @Test func replacingAVideoClearsChatAndCancelsTheOldProbe() throws {
        let coordinator = try makeCoordinator()
        let client = PipedClient(baseURL: try #require(URL(string: "https://example.com")))
        coordinator.liveChatLoader = LiveChatLoader(client: client, videoID: "old-live")
        coordinator.chatReplayLoader = LiveChatReplayLoader(client: client, videoID: "old-replay")
        coordinator.chatButtonModel.isVisible = true
        coordinator.chatButtonModel.isLive = true
        let oldProbe = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        coordinator.chatProbeTask = oldProbe
        defer { oldProbe.cancel() }

        coordinator.resetForItemReplacement(on: AVPlayer())

        #expect(oldProbe.isCancelled)
        #expect(coordinator.chatProbeTask == nil)
        #expect(coordinator.liveChatLoader == nil)
        #expect(coordinator.chatReplayLoader == nil)
        #expect(!coordinator.chatButtonModel.isVisible)
        #expect(!coordinator.chatButtonModel.isLive)
    }

    @Test func installingReplayDiscardsThePreviousLiveChat() throws {
        let coordinator = try makeCoordinator()
        let client = PipedClient(baseURL: try #require(URL(string: "https://example.com")))
        coordinator.liveChatLoader = LiveChatLoader(client: client, videoID: "old-live")
        coordinator.installChatAvailability(detail: streamPlaybackDetail(), client: client, videoID: "new-replay")
        defer { coordinator.resetChat() }
        #expect(coordinator.liveChatLoader == nil)
        #expect(coordinator.chatReplayLoader?.videoID == "new-replay")
    }

    @Test func diagnosticsOverlayIsInstalledOnceAndRemovedOnReplacement() throws {
        let coordinator = try makeCoordinator()
        let previous = coordinator.app.statsForNerdsEnabled
        coordinator.app.statsForNerdsEnabled = true
        defer { coordinator.app.statsForNerdsEnabled = previous }
        let controller = AVPlayerViewController()
        controller.player = AVPlayer()
        controller.loadViewIfNeeded()
        coordinator.installDebugOverlay(on: controller)
        let host = try #require(coordinator.debugOverlayHost)
        let count = controller.children.count
        coordinator.installDebugOverlay(on: controller)
        #expect(controller.children.count == count)
        #expect(coordinator.debugOverlayHost === host)

        coordinator.resetForItemReplacement(on: try #require(controller.player))
        #expect(coordinator.debugOverlayHost == nil)
        #expect(host.parent == nil)
        #expect(host.view.superview == nil)
    }
}
