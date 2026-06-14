import SwiftUI
import SwiftData
import UIKit
import PipedKit

/// Owns offline downloads: resolves a video's streams, fetches the media to disk,
/// tracks in-flight progress, and records a `DownloadedVideo` on success.
///
/// Completed downloads live in SwiftData (so they survive launches and drive the
/// Downloads list via `@Query`); in-flight ones live here in `active` so the UI
/// can show progress without persisting transient state.
@MainActor
@Observable
final class DownloadManager {
    /// In-flight and recently-failed downloads, keyed by video id.
    private(set) var active: [String: ActiveDownload] = [:]

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// A download in progress (or one that failed and is awaiting retry/dismiss).
    struct ActiveDownload: Identifiable, Equatable {
        let id: String          // videoID
        let title: String
        let uploader: String?
        let thumbnail: String?  // remote URL, shown until the file lands
        var state: State
        var fraction: Double

        enum State: Equatable {
            case preparing      // resolving streams
            case downloading
            case processing     // merging video + audio
            case failed(String)
        }

        var isFailed: Bool { if case .failed = state { return true }; return false }
    }

    // MARK: Queries

    func isDownloaded(_ videoID: String) -> Bool {
        let descriptor = FetchDescriptor<DownloadedVideo>(
            predicate: #Predicate { $0.videoID == videoID })
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    /// True while a download is running (failed entries don't count, so the menu
    /// can offer a fresh attempt).
    func isInFlight(_ videoID: String) -> Bool {
        guard let entry = active[videoID] else { return false }
        return !entry.isFailed
    }

    // MARK: Actions

    func download(_ item: StreamItem, using app: AppModel) {
        guard let videoID = item.videoID, !isDownloaded(videoID), tasks[videoID] == nil else { return }
        active[videoID] = ActiveDownload(
            id: videoID, title: item.displayTitle, uploader: item.uploaderName,
            thumbnail: item.thumbnail, state: .preparing, fraction: 0)
        let title = item.displayTitle, uploader = item.uploaderName, thumbnail = item.thumbnail
        tasks[videoID] = Task { [weak self] in
            await self?.perform(videoID: videoID, title: title, uploader: uploader,
                                thumbnail: thumbnail, app: app)
        }
    }

    /// Cancels an in-flight download and clears its temporary files.
    func cancel(_ videoID: String) {
        tasks[videoID]?.cancel()
        tasks[videoID] = nil
        active[videoID] = nil
        cleanupTemp(videoID)
    }

    /// Removes a completed download (file + poster + row) or cancels an in-flight one.
    func remove(_ videoID: String) {
        cancel(videoID)
        let descriptor = FetchDescriptor<DownloadedVideo>(
            predicate: #Predicate { $0.videoID == videoID })
        guard let row = try? modelContext.fetch(descriptor).first else { return }
        try? FileManager.default.removeItem(at: row.fileURL)
        if let thumb = row.thumbnailURL { try? FileManager.default.removeItem(at: thumb) }
        modelContext.delete(row)
    }

    /// Dismisses a failed entry from the list without touching the store.
    func dismissFailed(_ videoID: String) {
        guard active[videoID]?.isFailed == true else { return }
        active[videoID] = nil
        tasks[videoID] = nil
    }

    // MARK: Worker

    private func perform(videoID: String, title: String, uploader: String?,
                         thumbnail: String?, app: AppModel) async {
        do {
            NSLog("Atlas.download: ▶️ start \(videoID)")
            let detail = try await app.resolveStream(videoID)
            try Task.checkCancellation()

            let fileName = videoID + ".mp4"
            let output = DownloadStore.fileURL(fileName)
            var quality: String?

            if let source = detail.bestComposedSource(allowAV1: false) {
                // Best path: high-quality H.264 video-only + AAC audio, merged locally.
                quality = "\(source.height)p"
                NSLog("Atlas.download: composing \(source.height)p (video-only + audio)")
                let videoTmp = DownloadStore.fileURL(videoID + ".video.tmp")
                let audioTmp = DownloadStore.fileURL(videoID + ".audio.tmp")
                try await downloadPair(source.video, source.audio,
                                       videoDest: videoTmp, audioDest: audioTmp, videoID: videoID)
                try Task.checkCancellation()
                setState(videoID, .processing)
                NSLog("Atlas.download: merging to mp4")
                try await DownloadStore.mergeToMP4(video: videoTmp, audio: audioTmp, output: output)
                cleanupTemp(videoID)
            } else if let progressive = detail.bestProgressiveDownload {
                // Fallback: a single muxed file needs no merge.
                quality = progressive.height > 0 ? "\(progressive.height)p" : nil
                NSLog("Atlas.download: progressive \(quality ?? "?") single-file")
                setState(videoID, .downloading)
                try await DownloadStore.download(progressive.url, to: output) { [weak self] fraction in
                    Task { @MainActor in self?.setFraction(videoID, fraction) }
                }
            } else {
                throw PipedError.noPlayableStream
            }
            try Task.checkCancellation()

            DownloadStore.excludeFromBackup(output)
            let thumbName = await saveThumbnail(thumbnail, videoID: videoID)
            let row = DownloadedVideo(
                videoID: videoID, title: title, uploader: uploader,
                fileName: fileName, thumbnailFileName: thumbName,
                durationSeconds: detail.duration ?? 0, qualityLabel: quality,
                byteCount: DownloadStore.byteCount(of: output))
            modelContext.insert(row)
            NSLog("Atlas.download: ✅ done \(videoID) — \(DownloadStore.byteCount(of: output)) bytes")

            active[videoID] = nil
            tasks[videoID] = nil
        } catch is CancellationError {
            NSLog("Atlas.download: ⏹️ cancelled \(videoID)")
            cleanupTemp(videoID)
        } catch {
            NSLog("Atlas.download: ❌ failed \(videoID) — \(error.localizedDescription)")
            cleanupTemp(videoID)
            try? FileManager.default.removeItem(at: DownloadStore.fileURL(videoID + ".mp4"))
            active[videoID]?.state = .failed(error.localizedDescription)
            tasks[videoID] = nil
        }
    }

    /// Downloads the video-only then audio file, mapping each onto the overall
    /// progress bar (video is the bulk of the bytes, so it gets most of the bar).
    private func downloadPair(_ video: URL, _ audio: URL,
                              videoDest: URL, audioDest: URL, videoID: String) async throws {
        setState(videoID, .downloading)
        try await DownloadStore.download(video, to: videoDest) { [weak self] fraction in
            Task { @MainActor in self?.setFraction(videoID, fraction * 0.9) }
        }
        try Task.checkCancellation()
        try await DownloadStore.download(audio, to: audioDest) { [weak self] fraction in
            Task { @MainActor in self?.setFraction(videoID, 0.9 + fraction * 0.1) }
        }
    }

    /// Caches the poster locally so the Downloads list shows it offline. Best-effort.
    private func saveThumbnail(_ urlString: String?, videoID: String) async -> String? {
        let candidate = Thumbnail.upgraded(urlString) ?? urlString
        guard let candidate, let url = URL(string: candidate),
              let (data, _) = try? await URLSession.shared.data(from: url),
              UIImage(data: data) != nil else { return nil }
        let name = videoID + ".thumb"
        let dest = DownloadStore.fileURL(name)
        guard (try? data.write(to: dest)) != nil else { return nil }
        DownloadStore.excludeFromBackup(dest)
        return name
    }

    private func setState(_ videoID: String, _ state: ActiveDownload.State) {
        active[videoID]?.state = state
    }

    private func setFraction(_ videoID: String, _ fraction: Double) {
        guard active[videoID] != nil else { return }
        if active[videoID]?.state != .processing { active[videoID]?.state = .downloading }
        active[videoID]?.fraction = fraction
    }

    private func cleanupTemp(_ videoID: String) {
        try? FileManager.default.removeItem(at: DownloadStore.fileURL(videoID + ".video.tmp"))
        try? FileManager.default.removeItem(at: DownloadStore.fileURL(videoID + ".audio.tmp"))
    }
}
