import SwiftUI
import SwiftData
import UIKit
import PipedKit
import os

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

    private static let log = Logger(subsystem: "sh.cmf.atlas", category: "downloads")

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        reconcileOrphanedFiles()
    }

    /// Launch-time sweep: no download can be in flight yet (the download session
    /// is in-process), so leftover merge temps and final `.mp4`s without a
    /// completed row are orphans from a crash or kill — delete them.
    private func reconcileOrphanedFiles() {
        let completed = Set(
            ((try? modelContext.fetch(FetchDescriptor<DownloadedVideo>())) ?? []).map(\.fileName))
        Task.detached(priority: .utility) {
            DownloadStore.removeOrphanedFiles(completedFileNames: completed)
        }
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
        guard let videoID = item.videoID else { return }
        download(videoID: videoID, title: item.displayTitle, uploader: item.uploaderName,
                 thumbnail: item.thumbnail, using: app)
    }

    /// Core entry point used by the UI (via the `StreamItem` overload) and by the
    /// "Download this" App Intent, which only has the bare video fields to hand.
    func download(videoID: String, title: String, uploader: String?,
                  thumbnail: String?, using app: AppModel) {
        guard !isDownloaded(videoID), tasks[videoID] == nil else { return }
        active[videoID] = ActiveDownload(
            id: videoID, title: title, uploader: uploader,
            thumbnail: thumbnail, state: .preparing, fraction: 0)
        tasks[videoID] = Task { [weak self] in
            await self?.perform(videoID: videoID, title: title, uploader: uploader,
                                thumbnail: thumbnail, app: app)
        }
    }

    /// Cancels an in-flight download and clears its temporary files, including
    /// a partially written final `.mp4` (progressive downloads write straight to
    /// it). Only in-flight cancels touch the `.mp4` — once a download completes
    /// its task is cleared, so a completed file is never deleted here.
    func cancel(_ videoID: String) {
        let wasInFlight = tasks[videoID] != nil
        tasks[videoID]?.cancel()
        tasks[videoID] = nil
        active[videoID] = nil
        cleanupTemp(videoID)
        if wasInFlight {
            try? FileManager.default.removeItem(at: DownloadStore.fileURL(videoID + ".mp4"))
        }
    }

    /// Removes a completed download (file + poster + row) or cancels an in-flight one.
    func remove(_ videoID: String) {
        cancel(videoID)
        let descriptor = FetchDescriptor<DownloadedVideo>(
            predicate: #Predicate { $0.videoID == videoID })
        guard let row = try? modelContext.fetch(descriptor).first else { return }
        try? FileManager.default.removeItem(at: row.fileURL)
        if let thumb = row.thumbnailURL { try? FileManager.default.removeItem(at: thumb) }
        if let caption = row.captionURL { try? FileManager.default.removeItem(at: caption) }
        modelContext.delete(row)
        SpotlightIndexer.remove(videoID: videoID)
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
            Self.log.info("start \(videoID, privacy: .public)")
            let detail = try await app.resolveStream(videoID)
            try Task.checkCancellation()

            // Fail up front, with a clear message, if downloads storage
            // couldn't be created — never fall back to a transient location.
            _ = try DownloadStore.preparedDirectory()
            let fileName = videoID + ".mp4"
            let output = DownloadStore.fileURL(fileName)
            var quality: String?

            if let source = detail.bestComposedSource(allowAV1: false) {
                // Best path: high-quality H.264 video-only + AAC audio, merged locally.
                quality = "\(source.height)p"
                Self.log.info("composing \(source.height)p (video-only + audio)")
                // Keep mp4-family extensions: AVFoundation infers a file's
                // container from its path extension, and a `.tmp` extension makes
                // the merge fail to open the asset ("Cannot Open").
                let videoTmp = DownloadStore.fileURL(videoID + ".video.mp4")
                let audioTmp = DownloadStore.fileURL(videoID + ".audio.m4a")
                try await downloadPair(source.video, source.audio,
                                       videoDest: videoTmp, audioDest: audioTmp, videoID: videoID)
                try Task.checkCancellation()
                setState(videoID, .processing)
                Self.log.info("merging to mp4")
                try await DownloadStore.mergeToMP4(video: videoTmp, audio: audioTmp, output: output)
                cleanupTemp(videoID)
            } else if let progressive = detail.bestProgressiveDownload {
                // Fallback: a single muxed file needs no merge.
                quality = progressive.height > 0 ? "\(progressive.height)p" : nil
                Self.log.info("progressive \(quality ?? "?", privacy: .public) single-file")
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
            let caption = await saveCaption(detail.preferredSubtitle(), videoID: videoID)
            // A cancel during the (best-effort) sidecar saves above deletes the
            // media file, so don't record a row pointing at nothing.
            try Task.checkCancellation()
            let row = DownloadedVideo(
                videoID: videoID, title: title, uploader: uploader,
                fileName: fileName, thumbnailFileName: thumbName,
                captionFileName: caption?.fileName,
                captionMimeType: caption?.mimeType,
                captionLanguageCode: caption?.languageCode,
                captionName: caption?.name,
                durationSeconds: detail.duration ?? 0, qualityLabel: quality,
                byteCount: DownloadStore.byteCount(of: output))
            modelContext.insert(row)
            SpotlightIndexer.index(download: row)
            Self.log.info("done \(videoID, privacy: .public) — \(DownloadStore.byteCount(of: output)) bytes")

            active[videoID] = nil
            tasks[videoID] = nil
        } catch is CancellationError {
            Self.log.info("cancelled \(videoID, privacy: .public)")
            cleanupTemp(videoID)
            try? FileManager.default.removeItem(at: DownloadStore.fileURL(videoID + ".mp4"))
        } catch {
            Self.log.error("failed \(videoID, privacy: .public) — \(error.localizedDescription, privacy: .public)")
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

    private func saveCaption(
        _ subtitle: Subtitle?,
        videoID: String
    ) async -> (fileName: String, mimeType: String?, languageCode: String?, name: String?)? {
        guard let subtitle, let url = subtitle.usableURL,
              let (data, _) = try? await URLSession.shared.data(from: url),
              !data.isEmpty else { return nil }

        let ext = subtitle.mimeType?.lowercased().contains("vtt") == true ? "vtt" : "ttml"
        let name = videoID + ".captions." + ext
        let dest = DownloadStore.fileURL(name)
        guard (try? data.write(to: dest, options: .atomic)) != nil else { return nil }
        DownloadStore.excludeFromBackup(dest)
        return (name, subtitle.mimeType, subtitle.code, subtitle.name)
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
        try? FileManager.default.removeItem(at: DownloadStore.fileURL(videoID + ".video.mp4"))
        try? FileManager.default.removeItem(at: DownloadStore.fileURL(videoID + ".audio.m4a"))
    }
}
