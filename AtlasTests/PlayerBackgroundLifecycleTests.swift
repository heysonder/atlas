import AVKit
import Testing

@testable import Atlas

@Suite(.serialized)
@MainActor
struct PlayerBackgroundLifecycleTests {
    @Test(arguments: [false, true])
    func backgroundRoundTripRetainsPlayerAndMetadata(pipActive: Bool) async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let app = AppModel(
            instanceStore: InstanceStore(
                defaults: makeTestDefaults(), secureStore: MemoryInstanceSecureStore()))
        let downloads = DownloadManager(
            modelContext: context, storageMode: .recoveryReadOnly)
        let coordinator = VideoPlayerPresenter.Coordinator(
            app: app, downloads: downloads, modelContext: context, clearRequest: {})
        let player = PlayingPlayer()
        let item = AVPlayerItem(asset: AVMutableComposition())
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = "Background video" as NSString
        item.externalMetadata = [title]
        player.replaceCurrentItem(with: item)
        let controller = AVPlayerViewController()
        controller.player = player
        coordinator.player = player
        coordinator.playerVC = controller
        coordinator.pipActive = pipActive

        for notification in [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willEnterForegroundNotification,
        ] {
            NotificationCenter.default.post(name: notification, object: nil)
            // Allow lifecycle observers that dispatch onto the main actor to
            // run before checking ownership, including the former detach path.
            try await Task.sleep(for: .milliseconds(50))
            #expect(controller.player === player)
            #expect(controller.player?.currentItem === item)
            let retainedTitle = try await controller.player?.currentItem?.externalMetadata.first?.load(.stringValue)
            #expect(retainedTitle == "Background video")
        }
    }
}

/// Exercise the playing branch without a network stream or a running decoder.
private nonisolated final class PlayingPlayer: AVPlayer {
    override var timeControlStatus: AVPlayer.TimeControlStatus { .playing }
}
