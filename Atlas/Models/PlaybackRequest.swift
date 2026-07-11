import Foundation
import PipedKit

/// A request to open the full-screen player. Carries enough to show a header
/// immediately while the full stream details load.
struct PlayRequest: Identifiable, Hashable {
    let videoID: String
    let title: String
    let uploader: String?
    let thumbnail: String?
    /// When set, the player plays this local file directly and skips the network
    /// stream resolution entirely (offline playback of a download).
    let localURL: URL?
    /// Optional local caption file saved next to a downloaded video.
    let localCaptionURL: URL?
    let localCaptionMimeType: String?
    var id: String { videoID }

    nonisolated init(
        videoID: String, title: String, uploader: String? = nil,
        thumbnail: String? = nil, localURL: URL? = nil,
        localCaptionURL: URL? = nil, localCaptionMimeType: String? = nil
    ) {
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
        self.thumbnail = thumbnail
        self.localURL = localURL
        self.localCaptionURL = localCaptionURL
        self.localCaptionMimeType = localCaptionMimeType
    }

    nonisolated init?(item: StreamItem) {
        guard let videoID = item.videoID else { return nil }
        self.init(
            videoID: videoID,
            title: item.displayTitle,
            uploader: item.uploaderName,
            thumbnail: item.thumbnail)
    }

    @MainActor
    init(download: DownloadedVideo, fallbackThumbnail: String? = nil) {
        self.init(
            videoID: download.videoID,
            title: download.title,
            uploader: download.uploader,
            thumbnail: download.thumbnailURL?.absoluteString ?? fallbackThumbnail,
            localURL: download.fileURL,
            localCaptionURL: download.captionURL,
            localCaptionMimeType: download.captionMimeType)
    }
}

/// One transient item in the in-memory playback queue.
struct QueuedVideo: Identifiable, Hashable {
    let id: UUID
    let request: PlayRequest

    init(_ request: PlayRequest, id: UUID = UUID()) {
        self.id = id
        self.request = request
    }
}
