import Foundation

/// Owns the on-disk naming, containment, and cleanup rules for offline downloads.
/// `nonisolated` so the file helpers are reachable from `DownloadedVideo`'s
/// (nonisolated) computed URLs and from background download work.
nonisolated enum DownloadStore {
    enum StoreError: Error, LocalizedError, Equatable {
        case noTracks
        case exportUnavailable
        case exportFailed(String)
        case httpStatus(Int)
        case invalidVideoID
        case invalidFileName
        case storageUnavailable(String)
        case invalidRangeResponse
        case downloadTooLarge(maximumBytes: Int64)
        case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)

        var errorDescription: String? {
            switch self {
            case .noTracks: "The downloaded media was missing a video or audio track."
            case .exportUnavailable: "Couldn't prepare the file for offline playback."
            case .exportFailed(let message): "Saving the video failed: \(message)"
            case .httpStatus(let code): "The server rejected the download (HTTP \(code))."
            case .invalidVideoID: "The video identifier is not valid for offline storage."
            case .invalidFileName: "The saved download path is not valid."
            case .storageUnavailable(let message):
                "Downloads storage is unavailable: \(message)"
            case .invalidRangeResponse:
                "The media server returned an inconsistent byte range."
            case .downloadTooLarge(let maximumBytes):
                "The download exceeded the \(maximumBytes) byte safety limit."
            case .insufficientStorage(let requiredBytes, let availableBytes):
                "The download needs \(requiredBytes) bytes of free space, but only \(availableBytes) bytes are available."
            }
        }
    }

    enum Artifact: Sendable {
        case media
        case videoTemporary
        case audioTemporary
        case thumbnail
        case captionVTT
        case captionTTML

        fileprivate var suffix: String {
            switch self {
            case .media: ".mp4"
            case .videoTemporary: ".video.mp4"
            case .audioTemporary: ".audio.m4a"
            case .thumbnail: ".thumb"
            case .captionVTT: ".captions.vtt"
            case .captionTTML: ".captions.ttml"
            }
        }
    }

    private static let maximumVideoIDBytes = 128

    /// `Application Support/Downloads` — created on first access and kept out of
    /// iCloud/iTunes backups (media is large and re-downloadable). Resolution is
    /// strict — no tmp fallback, so persisted rows never point at purgeable
    /// files. If creation fails, `preparedDirectory()` surfaces the error at
    /// download time instead.
    private static let directoryResult: Result<URL, Error> = {
        let fm = FileManager.default
        do {
            let base = try fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("Downloads", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = dir
            try? mutable.setResourceValues(values)  // Best-effort; not worth failing storage over.
            return .success(dir)
        } catch {
            return .failure(error)
        }
    }()

    /// Best-effort directory URL, for resolving persisted file names to absolute
    /// URLs. Points at the Application Support location even when creation
    /// failed (reads simply miss); write paths use `preparedDirectory()`.
    static var directory: URL {
        (try? directoryResult.get())
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first.map { $0.appendingPathComponent("Downloads", isDirectory: true) }
            ?? URL(
                fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Downloads",
                isDirectory: true)
    }

    /// The downloads directory, verified created. Download work calls this first
    /// so a storage failure fails the download with a clear message instead of
    /// silently writing somewhere transient.
    static func preparedDirectory() throws -> URL {
        do {
            return try directoryResult.get()
        } catch {
            throw StoreError.storageUnavailable(error.localizedDescription)
        }
    }

    /// Piped video identifiers are opaque remote input. Restrict them to the
    /// ASCII alphabet YouTube uses before they can participate in a file name.
    static func isValidVideoID(_ videoID: String) -> Bool {
        guard !videoID.isEmpty,
            videoID.utf8.count <= maximumVideoIDBytes
        else { return false }
        return videoID.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 95, 97...122: true  // -, 0-9, A-Z, _, a-z
            default: false
            }
        }
    }

    static func fileName(videoID: String, artifact: Artifact) throws -> String {
        guard isValidVideoID(videoID) else { throw StoreError.invalidVideoID }
        return videoID + artifact.suffix
    }

    static func fileURL(videoID: String, artifact: Artifact) throws -> URL {
        let name = try fileName(videoID: videoID, artifact: artifact)
        guard let url = fileURL(name, expected: [artifact]) else {
            throw StoreError.invalidFileName
        }
        return url
    }

    /// Resolves a persisted app-owned basename. Legacy/corrupt rows fail closed:
    /// separators, traversal components, absolute paths, and unknown suffixes are
    /// never converted into a file URL.
    static func fileURL(_ name: String, in root: URL = directory) -> URL? {
        guard let artifact = artifact(for: name) else { return nil }
        return fileURL(name, expected: [artifact], in: root)
    }

    static func fileURL(
        _ name: String,
        expected artifacts: Set<Artifact>,
        in root: URL = directory
    ) -> URL? {
        guard let artifact = artifact(for: name),
            artifacts.contains(artifact)
        else { return nil }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = canonicalRoot.appendingPathComponent(name).standardizedFileURL
        guard
            candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                == canonicalRoot
        else { return nil }
        if FileManager.default.fileExists(atPath: candidate.path),
            (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        {
            return nil
        }
        return candidate
    }

    static func isValidStoredFileName(_ name: String) -> Bool {
        artifact(for: name) != nil
    }

    private static func artifact(for name: String) -> Artifact? {
        guard name == URL(fileURLWithPath: name).lastPathComponent,
            !name.contains("/"),
            !name.contains("\\")
        else { return nil }
        let artifacts: [Artifact] = [
            .videoTemporary, .audioTemporary, .captionVTT,
            .captionTTML, .thumbnail, .media,
        ]
        return artifacts.first { artifact in
            let suffix = artifact.suffix
            return name.hasSuffix(suffix)
                && isValidVideoID(String(name.dropLast(suffix.count)))
        }
    }

    static func contains(_ fileURL: URL, in root: URL = directory) -> Bool {
        guard fileURL.isFileURL else { return false }
        let standardizedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = fileURL.standardizedFileURL
        guard
            candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                == standardizedRoot
        else { return false }
        if FileManager.default.fileExists(atPath: candidate.path),
            (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        {
            return false
        }
        return true
    }

    // MARK: Orphan reconciliation

    /// App-owned files in the downloads directory that no completed row claims.
    /// Only the store's own naming patterns match; anything else is left alone.
    /// Pure, so it's directly testable.
    static func orphanedFileNames(in files: [String], claimedFileNames: Set<String>) -> [String] {
        files.filter { name in
            guard isValidStoredFileName(name) else { return false }
            return !claimedFileNames.contains(name)
        }
    }

    /// Deletes orphaned files inside `directory`. Called once at launch, when no
    /// download can be in flight (the download session is in-process).
    static func removeOrphanedFiles(
        claimedFileNames: Set<String>,
        in root: URL = directory
    ) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return
        }
        for name in orphanedFileNames(in: files, claimedFileNames: claimedFileNames) {
            guard let url = fileURL(name, in: root) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Flags a finished file so it isn't swept into device backups.
    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static func byteCount(of url: URL) -> Int64 {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(size ?? 0)
    }
}
