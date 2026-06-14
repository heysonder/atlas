import Foundation
import AVFoundation

/// Where offline downloads live on disk, plus the low-level file plumbing
/// (single-file download with progress, and the video+audio → mp4 merge).
/// `nonisolated` so the file helpers are reachable from `DownloadedVideo`'s
/// (nonisolated) computed URLs and from background download work.
nonisolated enum DownloadStore {
    enum StoreError: Error, LocalizedError {
        case noTracks
        case exportUnavailable
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noTracks: "The downloaded media was missing a video or audio track."
            case .exportUnavailable: "Couldn't prepare the file for offline playback."
            case .exportFailed(let m): "Saving the video failed: \(m)"
            }
        }
    }

    /// `Application Support/Downloads` — created on first access and kept out of
    /// iCloud/iTunes backups (media is large and re-downloadable).
    static let directory: URL = {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try? mutable.setResourceValues(values)
        return dir
    }()

    static func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name)
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

    /// ~4 MB per request. Small enough to never trip the per-request timeout on a
    /// slow link, large enough to keep request overhead negligible.
    private static let chunkSize: Int64 = 4 * 1024 * 1024

    /// A desktop-ish UA; some googlevideo edges throttle unknown clients harder.
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Downloads a remote file to `destination` in ranged chunks, reporting
    /// fractional progress.
    ///
    /// Chunking is essential for YouTube/Piped media URLs: a single full-file
    /// `GET` is throttled by the CDN and stalls until the request times out
    /// (the "timeout" you'd see in logs), whereas sequential `Range` requests
    /// stream reliably — the same way AVPlayer and yt-dlp fetch these URLs.
    static func download(_ url: URL, to destination: URL,
                         onProgress: @Sendable (Double) -> Void) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw URLError(.cannotCreateFile)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var total: Int64 = -1   // -1 = not yet known

        while total < 0 || offset < total {
            try Task.checkCancellation()
            let upperBound = total >= 0 ? min(offset + chunkSize, total) - 1 : offset + chunkSize - 1
            var request = URLRequest(url: url)
            request.setValue("bytes=\(offset)-\(upperBound)", forHTTPHeaderField: "Range")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await fetch(request, on: session)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200...299).contains(http.statusCode) else {
                throw URLError(URLError.Code(rawValue: http.statusCode))   // e.g. 403 / 429
            }

            try handle.write(contentsOf: data)
            offset += Int64(data.count)

            if total < 0 {
                // Trust Content-Range on a 206; a 200 means the server ignored the
                // Range and is streaming the whole file in this one response.
                total = http.statusCode == 206
                    ? (contentRangeTotal(http) ?? -1)
                    : http.expectedContentLength
            }
            if total > 0 { onProgress(min(Double(offset) / Double(total), 1)) }

            if http.statusCode == 200 { break }            // whole body already delivered
            if data.isEmpty { break }                      // defensive: no more bytes
            if total < 0 && Int64(data.count) < chunkSize { break }   // short read ⇒ EOF
        }

        if total > 0 && offset < total {
            throw URLError(.networkConnectionLost)   // truncated transfer
        }
    }

    /// Fetches one chunk, retrying a few times on transient network errors
    /// (timeouts, dropped connections) with a short backoff — these are common on
    /// throttled media edges and almost always succeed on a retry.
    private static func fetch(_ request: URLRequest, on session: URLSession,
                              attempts: Int = 4) async throws -> (Data, URLResponse) {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<attempts {
            do {
                return try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where Self.isRetryable(error) {
                lastError = error
                NSLog("Atlas.download: chunk retry \(attempt + 1)/\(attempts) — \(error.code.rawValue)")
                try await Task.sleep(for: .seconds(1 << attempt))   // 1s, 2s, 4s …
            }
        }
        throw lastError
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable:
            true
        default:
            false
        }
    }

    /// Parses the total size from a `Content-Range: bytes 0-4194303/52428800` header.
    private static func contentRangeTotal(_ http: HTTPURLResponse) -> Int64? {
        guard let value = http.value(forHTTPHeaderField: "Content-Range"),
              let slash = value.lastIndex(of: "/") else { return nil }
        let tail = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return tail == "*" ? nil : Int64(tail)
    }

    /// Merges a separately-downloaded video-only file and audio file into a single
    /// `.mp4` using a passthrough export — no re-encode, so it's fast and keeps the
    /// original H.264/AAC quality.
    nonisolated static func mergeToMP4(video: URL, audio: URL, output: URL) async throws {
        // Hint the container type so the parse doesn't depend solely on the file
        // extension — a wrong/unknown extension otherwise fails with "Cannot Open".
        let videoAsset = AVURLAsset(url: video, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        let audioAsset = AVURLAsset(url: audio, options: [AVURLAssetOverrideMIMETypeKey: "audio/mp4"])
        let composition = AVMutableComposition()

        guard let vTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let aTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let vComp = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid),
              let aComp = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw StoreError.noTracks }

        let vDuration = try await videoAsset.load(.duration)
        let aDuration = try await audioAsset.load(.duration)
        try vComp.insertTimeRange(CMTimeRange(start: .zero, duration: vDuration), of: vTrack, at: .zero)
        try aComp.insertTimeRange(CMTimeRange(start: .zero, duration: min(vDuration, aDuration)),
                                  of: aTrack, at: .zero)

        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetPassthrough) else {
            throw StoreError.exportUnavailable
        }
        try? FileManager.default.removeItem(at: output)
        do {
            try await export.export(to: output, as: .mp4)
        } catch {
            throw StoreError.exportFailed(error.localizedDescription)
        }
    }
}
