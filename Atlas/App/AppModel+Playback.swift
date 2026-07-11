import PipedKit
import SwiftUI

extension AppModel {
    var canAddToQueueAtEnd: Bool {
        !queuedVideos.isEmpty
    }

    func play(_ item: StreamItem) {
        guard let request = PlayRequest(item: item) else { return }
        nowPlaying = request
    }

    func playNext(_ request: PlayRequest) {
        queuedVideos.insert(QueuedVideo(request), at: 0)
    }

    func addToQueue(_ request: PlayRequest) {
        queuedVideos.append(QueuedVideo(request))
    }

    func removeFromQueue(_ queued: QueuedVideo) -> PlayRequest? {
        guard let index = queuedVideos.firstIndex(where: { $0.id == queued.id }) else { return nil }
        return queuedVideos.remove(at: index).request
    }

    func moveQueuedVideos(from offsets: IndexSet, to destination: Int) {
        queuedVideos.move(fromOffsets: offsets, toOffset: destination)
    }

    func dequeueNext() -> PlayRequest? {
        guard !queuedVideos.isEmpty else { return nil }
        return queuedVideos.removeFirst().request
    }

    func clearQueue() {
        queuedVideos.removeAll()
    }

    func playPlaylistVideo(_ video: PlaylistVideo) {
        nowPlaying = PlayRequest(
            videoID: video.videoID, title: video.title,
            uploader: video.uploader, thumbnail: video.thumbnailURL)
    }

    func playDownloaded(_ video: DownloadedVideo) {
        nowPlaying = PlayRequest(download: video)
    }
}
