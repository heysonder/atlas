import Foundation
import SwiftData

/// A video saved to disk for offline playback. The media and its poster live as
/// files under `DownloadStore.directory`; we persist only their *file names* (not
/// absolute URLs), since the app's container path can change between launches.
@Model
final class DownloadedVideo {
    @Attribute(.unique) var videoID: String
    var title: String
    var uploader: String?
    /// Relative file name of the downloaded `.mp4`, e.g. "VIDEOID.mp4".
    var fileName: String
    /// Relative file name of the locally cached poster, so it shows offline.
    var thumbnailFileName: String?
    /// Relative file name of the selected caption track, when the source had one.
    var captionFileName: String?
    var captionMimeType: String?
    var captionLanguageCode: String?
    var captionName: String?
    var durationSeconds: Int
    /// Human label like "1080p", when the source resolution is known.
    var qualityLabel: String?
    /// On-disk size of the media file, for display.
    var byteCount: Int64
    var createdAt: Date

    init(videoID: String, title: String, uploader: String? = nil,
         fileName: String, thumbnailFileName: String? = nil,
         captionFileName: String? = nil, captionMimeType: String? = nil,
         captionLanguageCode: String? = nil, captionName: String? = nil,
         durationSeconds: Int = 0, qualityLabel: String? = nil,
         byteCount: Int64 = 0, createdAt: Date = .now) {
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
        self.fileName = fileName
        self.thumbnailFileName = thumbnailFileName
        self.captionFileName = captionFileName
        self.captionMimeType = captionMimeType
        self.captionLanguageCode = captionLanguageCode
        self.captionName = captionName
        self.durationSeconds = durationSeconds
        self.qualityLabel = qualityLabel
        self.byteCount = byteCount
        self.createdAt = createdAt
    }

    /// Absolute URL of the media file, resolved against the current container.
    var fileURL: URL { DownloadStore.fileURL(fileName) }
    /// Absolute URL of the cached poster, if one was saved.
    var thumbnailURL: URL? { thumbnailFileName.map(DownloadStore.fileURL) }
    /// Absolute URL of the caption track, if one was saved.
    var captionURL: URL? { captionFileName.map(DownloadStore.fileURL) }
}
