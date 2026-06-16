import AVFoundation
import SwiftData
import PipedKit

@MainActor
enum PlaybackHistoryStore {
    static let minWatchSeconds: Double = 5

    static func savedPosition(for videoID: String, in context: ModelContext) -> Double? {
        let descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { $0.videoID == videoID })
        guard let entry = try? context.fetch(descriptor).first else { return nil }
        if entry.durationSeconds > 0, entry.positionSeconds >= entry.durationSeconds - 10 {
            return nil
        }
        return entry.positionSeconds
    }

    static func savePosition(_ seconds: Double, videoID: String, duration: Double?,
                             in context: ModelContext) {
        guard seconds.isFinite, seconds >= minWatchSeconds else { return }
        let descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { $0.videoID == videoID })
        guard let entry = try? context.fetch(descriptor).first else { return }
        entry.positionSeconds = seconds
        if entry.durationSeconds == 0, let duration, duration.isFinite, duration > 0 {
            entry.durationSeconds = duration
        }
        entry.watchedAt = .now
    }

    static func record(_ request: PlayRequest, detail: VideoDetail? = nil,
                       in context: ModelContext) {
        record(videoID: request.videoID,
               title: detail?.title ?? request.title,
               uploader: detail?.uploader ?? request.uploader,
               thumbnailURL: detail?.thumbnailUrl ?? request.thumbnail,
               in: context)
    }

    static func record(videoID: String, title: String, uploader: String?,
                       thumbnailURL: String?, in context: ModelContext) {
        let descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { $0.videoID == videoID })
        if let existing = try? context.fetch(descriptor).first {
            existing.watchedAt = .now
        } else {
            context.insert(HistoryEntry(
                videoID: videoID,
                title: title,
                uploader: uploader,
                thumbnailURL: thumbnailURL))
        }
    }
}
