import Foundation
import Observation
import PipedKit
import SwiftData
import os

typealias DownloadReconciler = @Sendable (Set<String>) async -> Void

enum DownloadStorageMode: Sendable {
    case persistent
    case recoveryReadOnly
}

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
    @ObservationIgnored private let storageMode: DownloadStorageMode
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "sh.cmf.atlas", category: "downloads")

    init(
        modelContext: ModelContext,
        storageMode: DownloadStorageMode,
        reconcileOnInit: Bool = true,
        reconciler: @escaping DownloadReconciler = { claimedFileNames in
            await Task.detached(priority: .utility) {
                DownloadStore.removeOrphanedFiles(claimedFileNames: claimedFileNames)
            }.value
        }
    ) {
        self.modelContext = modelContext
        self.storageMode = storageMode
        if storageMode == .persistent, reconcileOnInit {
            reconciliationTask = makeReconciliationTask(using: reconciler)
        }
    }

    /// Launch-time sweep for crash leftovers. New downloads wait for this task,
    /// so files created by live work can never be mistaken for startup orphans.
    private func makeReconciliationTask(
        using reconciler: @escaping DownloadReconciler
    ) -> Task<Void, Never>? {
        guard
            let claimedFileNames = Self.reconciliationFileNames(
                canReconcilePersistentDownloads: true,
                fetch: {
                    try modelContext.fetch(FetchDescriptor<DownloadedVideo>()).flatMap { download in
                        [
                            download.fileName,
                            download.thumbnailFileName,
                            download.captionFileName,
                        ].compactMap { $0 }
                    }
                })
        else { return nil }
        return Task {
            await reconciler(claimedFileNames)
        }
    }

    /// Returns nil unless destructive reconciliation has positive evidence from
    /// persistent storage. Kept as a small seam so recovery and fetch failures
    /// can be regression-tested without touching the user's real download folder.
    static func reconciliationFileNames(
        canReconcilePersistentDownloads: Bool,
        fetch: () throws -> [String]
    ) -> Set<String>? {
        guard canReconcilePersistentDownloads,
            let names = try? fetch()
        else { return nil }
        return Set(names.filter(DownloadStore.isValidStoredFileName))
    }

    /// A download in progress (or one that failed and is awaiting retry/dismiss).
    struct ActiveDownload: Identifiable, Equatable {
        let id: String  // videoID
        let title: String
        let uploader: String?
        let thumbnail: String?  // remote URL, shown until the file lands
        var state: State
        var fraction: Double

        enum State: Equatable {
            case preparing  // resolving streams
            case downloading
            case processing  // merging video + audio
            case failed(String)
        }

        var isFailed: Bool {
            if case .failed = state {
                return true
            }
            return false
        }
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
        download(
            videoID: videoID, title: item.displayTitle, uploader: item.uploaderName,
            thumbnail: item.thumbnail, using: app)
    }

    /// Core entry point used by the UI (via the `StreamItem` overload) and by the
    /// "Download this" App Intent, which only has the bare video fields to hand.
    func download(
        videoID: String, title: String, uploader: String?,
        thumbnail: String?, using app: AppModel
    ) {
        guard DownloadStore.isValidVideoID(videoID),
            storageMode == .persistent,
            canStartDownload(videoID),
            tasks[videoID] == nil
        else { return }
        active[videoID] = ActiveDownload(
            id: videoID, title: title, uploader: uploader,
            thumbnail: thumbnail, state: .preparing, fraction: 0)
        let startupReconciliation = reconciliationTask
        tasks[videoID] = Task { [weak self] in
            await startupReconciliation?.value
            guard !Task.isCancelled else {
                self?.finishCancelledBeforeStart(videoID)
                return
            }
            await self?.performDownload(
                videoID: videoID,
                title: title,
                uploader: uploader,
                thumbnail: thumbnail,
                app: app
            )
        }
    }

    private func finishCancelledBeforeStart(_ videoID: String) {
        active[videoID] = nil
        tasks[videoID] = nil
    }

    private func canStartDownload(_ videoID: String) -> Bool {
        let descriptor = FetchDescriptor<DownloadedVideo>(
            predicate: #Predicate { $0.videoID == videoID })
        guard let count = try? modelContext.fetchCount(descriptor) else {
            // A query failure leaves the on-disk inventory unknown. Refuse to
            // create/truncate a potentially existing file until it is readable.
            return false
        }
        return count == 0
    }

    /// Cancels an in-flight download and clears its temporary files, including
    /// a partially written final `.mp4` (progressive downloads write straight to
    /// it). Only in-flight cancels touch the `.mp4` — once a download completes
    /// its task is cleared, so a completed file is never deleted here.
    func cancel(_ videoID: String) {
        let wasInFlight = tasks[videoID] != nil
        tasks[videoID]?.cancel()
        active[videoID] = nil
        removeTemporaryFiles(videoID)
        if wasInFlight,
            let output = try? DownloadStore.fileURL(videoID: videoID, artifact: .media)
        {
            try? FileManager.default.removeItem(at: output)
        }
    }

    /// Removes a completed download (file + poster + row) or cancels an in-flight one.
    func remove(_ videoID: String) {
        cancel(videoID)
        let descriptor = FetchDescriptor<DownloadedVideo>(
            predicate: #Predicate { $0.videoID == videoID })
        guard let row = try? modelContext.fetch(descriptor).first else { return }
        if let fileURL = row.fileURL { try? FileManager.default.removeItem(at: fileURL) }
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

    private func performDownload(
        videoID: String,
        title: String,
        uploader: String?,
        thumbnail: String?,
        app: AppModel
    ) async {
        do {
            Self.log.info("start video=\(videoID, privacy: .private(mask: .hash))")
            let detail = try await app.resolveStream(videoID)
            let httpClient = try app.httpClient
            try Task.checkCancellation()

            // Fail up front, with a clear message, if downloads storage
            // couldn't be created — never fall back to a transient location.
            _ = try DownloadStore.preparedDirectory()
            let fileName = try DownloadStore.fileName(videoID: videoID, artifact: .media)
            let output = try DownloadStore.fileURL(videoID: videoID, artifact: .media)
            var qualityLabel: String?

            if let source = detail.bestComposedSource(allowAV1: false) {
                // Best path: high-quality H.264 video-only + AAC audio, merged locally.
                qualityLabel = "\(source.height)p"
                Self.log.info("composing \(source.height)p (video-only + audio)")
                // Keep mp4-family extensions: AVFoundation infers a file's
                // container from its path extension, and a `.tmp` extension makes
                // the merge fail to open the asset ("Cannot Open").
                let videoTmp = try DownloadStore.fileURL(
                    videoID: videoID, artifact: .videoTemporary)
                let audioTmp = try DownloadStore.fileURL(
                    videoID: videoID, artifact: .audioTemporary)
                try await downloadPair(
                    video: source.video,
                    audio: source.audio,
                    videoDestination: videoTmp,
                    audioDestination: audioTmp,
                    videoID: videoID,
                    client: httpClient)
                try Task.checkCancellation()
                setState(videoID, .processing)
                Self.log.info("merging to mp4")
                try await DownloadStore.mergeToMP4(video: videoTmp, audio: audioTmp, output: output)
                removeTemporaryFiles(videoID)
            } else if let progressive = detail.bestProgressiveDownload {
                // Fallback: a single muxed file needs no merge.
                qualityLabel = progressive.height > 0 ? "\(progressive.height)p" : nil
                Self.log.info(
                    "progressive \(qualityLabel ?? "?", privacy: .public) single-file"
                )
                setState(videoID, .downloading)
                try await DownloadStore.download(
                    progressive.url, to: output, client: httpClient
                ) { [weak self] fraction in
                    Task { @MainActor in self?.setFraction(videoID, fraction) }
                }
            } else {
                throw PipedError.noPlayableStream
            }
            try Task.checkCancellation()

            DownloadStore.excludeFromBackup(output)
            let thumbnailFileName = await downloadThumbnailSidecar(
                thumbnail, videoID: videoID, client: httpClient)
            let caption = await downloadCaptionSidecar(
                detail.preferredSubtitle(), videoID: videoID, client: httpClient)
            // A cancel during the (best-effort) sidecar saves above deletes the
            // media file, so don't record a row pointing at nothing.
            try Task.checkCancellation()
            let row = DownloadedVideo(
                videoID: videoID, title: title, uploader: uploader,
                fileName: fileName, thumbnailFileName: thumbnailFileName,
                captionFileName: caption?.fileName,
                captionMimeType: caption?.mimeType,
                captionLanguageCode: caption?.languageCode,
                captionName: caption?.name,
                durationSeconds: detail.duration ?? 0, qualityLabel: qualityLabel,
                byteCount: DownloadStore.byteCount(of: output))
            modelContext.insert(row)
            SpotlightIndexer.index(download: row)
            Self.log.info(
                "done video=\(videoID, privacy: .private(mask: .hash)) bytes=\(DownloadStore.byteCount(of: output), privacy: .public)"
            )

            active[videoID] = nil
            tasks[videoID] = nil
        } catch is CancellationError {
            Self.log.info("cancelled video=\(videoID, privacy: .private(mask: .hash))")
            removeTemporaryFiles(videoID)
            if let output = try? DownloadStore.fileURL(videoID: videoID, artifact: .media) {
                try? FileManager.default.removeItem(at: output)
            }
            active[videoID] = nil
            tasks[videoID] = nil
        } catch {
            let failure = error as NSError
            Self.log.error(
                "failed video=\(videoID, privacy: .private(mask: .hash)) domain=\(PlaybackDiagnostics.safeToken(failure.domain), privacy: .public) code=\(failure.code, privacy: .public)"
            )
            removeTemporaryFiles(videoID)
            if let output = try? DownloadStore.fileURL(videoID: videoID, artifact: .media) {
                try? FileManager.default.removeItem(at: output)
            }
            active[videoID]?.state = .failed(error.localizedDescription)
            tasks[videoID] = nil
        }
    }

    /// Downloads the video-only then audio file, mapping each onto the overall
    /// progress bar (video is the bulk of the bytes, so it gets most of the bar).
    private func downloadPair(
        video: URL,
        audio: URL,
        videoDestination: URL,
        audioDestination: URL,
        videoID: String,
        client: PolicyHTTPClient
    ) async throws {
        setState(videoID, .downloading)
        try await DownloadStore.download(
            video,
            to: videoDestination,
            client: client
        ) { [weak self] fraction in
            Task { @MainActor in self?.setFraction(videoID, fraction * 0.9) }
        }
        try Task.checkCancellation()
        try await DownloadStore.download(
            audio,
            to: audioDestination,
            client: client
        ) { [weak self] fraction in
            Task { @MainActor in self?.setFraction(videoID, 0.9 + fraction * 0.1) }
        }
    }

    /// Caches the poster locally so the Downloads list shows it offline. Best-effort.
    private func downloadThumbnailSidecar(
        _ urlString: String?,
        videoID: String,
        client: PolicyHTTPClient
    ) async -> String? {
        let candidate = ThumbnailURL.upgraded(urlString) ?? urlString
        guard let candidate, let url = URL(string: candidate),
            let (data, _) = try? await client.data(from: url)
        else { return nil }
        guard let name = try? DownloadStore.fileName(videoID: videoID, artifact: .thumbnail),
            let destination = try? DownloadStore.fileURL(
                videoID: videoID,
                artifact: .thumbnail
            )
        else { return nil }
        let written = await Task.detached(priority: .utility) {
            guard DownloadSidecarWriter.writeThumbnail(data, to: destination) else { return false }
            DownloadStore.excludeFromBackup(destination)
            return true
        }.value
        guard written else { return nil }
        return name
    }

    private func downloadCaptionSidecar(
        _ subtitle: Subtitle?,
        videoID: String,
        client: PolicyHTTPClient
    ) async -> (fileName: String, mimeType: String?, languageCode: String?, name: String?)? {
        guard let subtitle, let url = subtitle.usableURL,
            let (data, _) = try? await client.data(from: url),
            !data.isEmpty
        else { return nil }

        let artifact: DownloadStore.Artifact =
            subtitle.mimeType?.lowercased().contains("vtt") == true
            ? .captionVTT : .captionTTML
        guard let name = try? DownloadStore.fileName(videoID: videoID, artifact: artifact),
            let destination = try? DownloadStore.fileURL(videoID: videoID, artifact: artifact)
        else { return nil }
        let written = await Task.detached(priority: .utility) {
            guard DownloadSidecarWriter.write(data, to: destination) else { return false }
            DownloadStore.excludeFromBackup(destination)
            return true
        }.value
        guard written else { return nil }
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

    private func removeTemporaryFiles(_ videoID: String) {
        if let video = try? DownloadStore.fileURL(videoID: videoID, artifact: .videoTemporary) {
            try? FileManager.default.removeItem(at: video)
        }
        if let audio = try? DownloadStore.fileURL(videoID: videoID, artifact: .audioTemporary) {
            try? FileManager.default.removeItem(at: audio)
        }
    }
}
