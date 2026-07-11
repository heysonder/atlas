import Foundation
import PipedKit
import os

nonisolated extension DownloadStore {
    /// A single temporary audio or video track is capped at 8 GiB. The merge
    /// output is separately constrained by the two already-bounded inputs.
    static let maximumDownloadBytes: Int64 = 8 * 1024 * 1024 * 1024

    /// Keeps headroom for the OS, database writes, and the companion track.
    static let minimumFreeCapacityReserveBytes: Int64 = 256 * 1024 * 1024

    typealias ChunkStreamer =
        @Sendable (
            URLRequest,
            PolicyHTTPClient,
            Int64,
            @escaping @Sendable (URLResponse) throws -> Void,
            @escaping @Sendable (Data) throws -> PolicyStreamDisposition
        ) async throws -> PolicyStreamResult

    typealias CapacityProvider = @Sendable (URL) -> Int64?

    private static let log = Logger(subsystem: "sh.cmf.atlas", category: "downloads")

    /// About 4 MiB per request balances slow-link reliability with request overhead.
    private static let chunkSize: Int64 = 4 * 1024 * 1024

    /// A desktop-style user agent avoids throttling by some media edges.
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Downloads a remote file in bounded range requests and reports progress.
    static func download(
        _ url: URL,
        to destination: URL,
        client: PolicyHTTPClient,
        onProgress: @Sendable (Double) -> Void
    ) async throws {
        try await downloadStreaming(
            url,
            to: destination,
            client: client,
            root: directory,
            capacityProvider: availableCapacity,
            streamer: { request, client, maximumBytes, onResponse, onData in
                try await client.stream(
                    for: request,
                    maximumResponseBytes: maximumBytes,
                    onResponse: onResponse,
                    onData: onData
                )
            },
            onProgress: onProgress
        )
    }

    static func downloadStreaming(
        _ url: URL,
        to destination: URL,
        client: PolicyHTTPClient,
        root: URL,
        capacityProvider: @escaping CapacityProvider,
        streamer: ChunkStreamer,
        onProgress: @Sendable (Double) -> Void
    ) async throws {
        guard contains(destination, in: root) else {
            throw StoreError.invalidFileName
        }
        try client.context.validate(url)

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw URLError(.cannotCreateFile)
        }

        var completed = false
        defer {
            if !completed {
                try? fileManager.removeItem(at: destination)
            }
        }

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var totalByteCount: Int64?
        var reportedCompletion = false

        while totalByteCount.map({ offset < $0 }) ?? true {
            try Task.checkCancellation()
            guard offset < maximumDownloadBytes else {
                throw StoreError.downloadTooLarge(maximumBytes: maximumDownloadBytes)
            }

            let remainingToLimit = maximumDownloadBytes - offset
            let remainingToTotal = totalByteCount.map { $0 - offset } ?? remainingToLimit
            let requestedLength = min(chunkSize, remainingToLimit, remainingToTotal)
            guard requestedLength > 0 else {
                throw StoreError.invalidRangeResponse
            }

            let (nextOffset, overflow) = offset.addingReportingOverflow(requestedLength)
            guard !overflow else { throw StoreError.invalidRangeResponse }
            let requestedUpperBound = nextOffset - 1

            var request = URLRequest(url: url)
            request.setValue(
                "bytes=\(offset)-\(requestedUpperBound)",
                forHTTPHeaderField: "Range"
            )
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            var outcome: StreamedChunkOutcome?
            var lastError: Error?
            for attempt in 0..<4 {
                let receiver = StreamedChunkReceiver(
                    destination: destination,
                    handle: handle,
                    offset: offset,
                    requestedUpperBound: requestedUpperBound,
                    knownTotalByteCount: totalByteCount,
                    capacityProvider: capacityProvider
                )
                do {
                    _ = try await streamer(
                        request,
                        client,
                        maximumDownloadBytes,
                        receiver.receive,
                        receiver.receive
                    )
                    outcome = try receiver.finish()
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where isRetryable(error) && attempt < 3 {
                    lastError = error
                    try handle.truncate(atOffset: UInt64(offset))
                    try handle.seek(toOffset: UInt64(offset))
                    log.debug(
                        "chunk retry attempt=\(attempt + 1, privacy: .public) maximum=4 code=\(error.code.rawValue, privacy: .public)"
                    )
                    try await Task.sleep(for: .seconds(1 << attempt))
                } catch {
                    throw error
                }
            }

            guard let outcome else {
                throw lastError ?? URLError(.unknown)
            }
            if outcome.reachedEnd {
                totalByteCount = outcome.totalByteCount ?? offset
                break
            }
            if let responseTotalByteCount = outcome.totalByteCount {
                guard totalByteCount == nil || totalByteCount == responseTotalByteCount else {
                    throw StoreError.invalidRangeResponse
                }
                totalByteCount = responseTotalByteCount
            }

            let (updatedOffset, bodyOverflow) = offset.addingReportingOverflow(
                outcome.byteCount
            )
            guard !bodyOverflow, updatedOffset <= maximumDownloadBytes else {
                throw StoreError.downloadTooLarge(maximumBytes: maximumDownloadBytes)
            }
            offset = updatedOffset

            if let totalByteCount, totalByteCount > 0 {
                let progress = min(max(Double(offset) / Double(totalByteCount), 0), 1)
                onProgress(progress)
                reportedCompletion = progress == 1
            } else {
                let boundedProgress = min(
                    max(Double(offset) / Double(maximumDownloadBytes), 0),
                    0.99
                )
                onProgress(boundedProgress)
            }

            if outcome.statusCode == 200 { break }
            guard outcome.byteCount > 0 else {
                throw StoreError.invalidRangeResponse
            }
        }

        if let totalByteCount, offset < totalByteCount {
            throw URLError(.networkConnectionLost)
        }
        completed = true
        if !reportedCompletion {
            onProgress(1)
        }
    }

    private struct StreamedChunkOutcome {
        let statusCode: Int
        let byteCount: Int64
        let totalByteCount: Int64?
        let reachedEnd: Bool
    }

    private final class StreamedChunkReceiver: @unchecked Sendable {
        private let destination: URL
        private let handle: FileHandle
        private let offset: Int64
        private let requestedUpperBound: Int64
        private let knownTotalByteCount: Int64?
        private let capacityProvider: CapacityProvider

        private var statusCode = 0
        private var expectedBodyByteCount: Int64?
        private var responseTotalByteCount: Int64?
        private var byteCount: Int64 = 0
        private var reachedEnd = false

        init(
            destination: URL,
            handle: FileHandle,
            offset: Int64,
            requestedUpperBound: Int64,
            knownTotalByteCount: Int64?,
            capacityProvider: @escaping CapacityProvider
        ) {
            self.destination = destination
            self.handle = handle
            self.offset = offset
            self.requestedUpperBound = requestedUpperBound
            self.knownTotalByteCount = knownTotalByteCount
            self.capacityProvider = capacityProvider
        }

        func receive(response: URLResponse) throws {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            switch httpResponse.statusCode {
            case 206:
                try receivePartialResponse(httpResponse)
            case 200:
                try receiveCompleteResponse(httpResponse)
            case 416:
                try receiveRangeNotSatisfiableResponse(httpResponse)
            default:
                throw StoreError.httpStatus(httpResponse.statusCode)
            }
            statusCode = httpResponse.statusCode
            try requireCapacityForRemainingResponse()
        }

        func receive(data: Data) throws -> PolicyStreamDisposition {
            guard statusCode != 416 else { return .stopLoading }

            let bodyLimit = expectedBodyByteCount ?? (maximumDownloadBytes - offset)
            let (nextByteCount, overflow) = byteCount.addingReportingOverflow(
                Int64(data.count)
            )
            guard !overflow, nextByteCount <= bodyLimit else {
                throw expectedBodyByteCount == nil
                    ? StoreError.downloadTooLarge(maximumBytes: maximumDownloadBytes)
                    : StoreError.invalidRangeResponse
            }

            let (requiredCapacity, capacityOverflow) = Int64(data.count)
                .addingReportingOverflow(minimumFreeCapacityReserveBytes)
            guard !capacityOverflow else {
                throw StoreError.downloadTooLarge(maximumBytes: maximumDownloadBytes)
            }
            if let availableCapacity = capacityProvider(destination),
                availableCapacity < requiredCapacity
            {
                throw StoreError.insufficientStorage(
                    requiredBytes: requiredCapacity,
                    availableBytes: availableCapacity
                )
            }

            try handle.write(contentsOf: data)
            byteCount = nextByteCount
            return .continueLoading
        }

        func finish() throws -> StreamedChunkOutcome {
            guard statusCode != 0 else {
                throw URLError(.badServerResponse)
            }
            if let expectedBodyByteCount, byteCount != expectedBodyByteCount {
                throw StoreError.invalidRangeResponse
            }
            if statusCode == 200 {
                if let responseTotalByteCount, byteCount != responseTotalByteCount {
                    throw URLError(.networkConnectionLost)
                }
                responseTotalByteCount = responseTotalByteCount ?? byteCount
            }
            return StreamedChunkOutcome(
                statusCode: statusCode,
                byteCount: byteCount,
                totalByteCount: responseTotalByteCount,
                reachedEnd: reachedEnd
            )
        }

        private func receivePartialResponse(_ response: HTTPURLResponse) throws {
            guard let contentRange = HTTPByteContentRange(response),
                let receivedRange = contentRange.range,
                receivedRange.lowerBound == offset,
                receivedRange.upperBound <= requestedUpperBound,
                let bodyByteCount = HTTPByteContentRange.byteCount(of: receivedRange)
            else {
                throw StoreError.invalidRangeResponse
            }
            if response.expectedContentLength >= 0,
                response.expectedContentLength != bodyByteCount
            {
                throw StoreError.invalidRangeResponse
            }
            if let declaredTotalByteCount = contentRange.totalByteCount {
                guard declaredTotalByteCount <= maximumDownloadBytes,
                    declaredTotalByteCount > receivedRange.upperBound,
                    knownTotalByteCount == nil
                        || knownTotalByteCount == declaredTotalByteCount
                else {
                    throw declaredTotalByteCount > maximumDownloadBytes
                        ? StoreError.downloadTooLarge(maximumBytes: maximumDownloadBytes)
                        : StoreError.invalidRangeResponse
                }
                responseTotalByteCount = declaredTotalByteCount
            } else if knownTotalByteCount != nil {
                throw StoreError.invalidRangeResponse
            }
            expectedBodyByteCount = bodyByteCount
        }

        private func receiveCompleteResponse(_ response: HTTPURLResponse) throws {
            guard offset == 0 else { throw StoreError.invalidRangeResponse }
            if response.expectedContentLength >= 0 {
                guard response.expectedContentLength <= maximumDownloadBytes else {
                    throw StoreError.downloadTooLarge(maximumBytes: maximumDownloadBytes)
                }
                responseTotalByteCount = response.expectedContentLength
            }
        }

        private func receiveRangeNotSatisfiableResponse(
            _ response: HTTPURLResponse
        ) throws {
            guard let contentRange = HTTPByteContentRange(response),
                contentRange.range == nil,
                contentRange.totalByteCount == offset,
                knownTotalByteCount == nil || knownTotalByteCount == offset
            else {
                throw StoreError.invalidRangeResponse
            }
            responseTotalByteCount = offset
            reachedEnd = true
        }

        private func requireCapacityForRemainingResponse() throws {
            let remainingByteCount =
                responseTotalByteCount.map { $0 - offset }
                ?? expectedBodyByteCount
            guard let remainingByteCount else { return }

            let (requiredCapacity, overflow) = remainingByteCount.addingReportingOverflow(
                minimumFreeCapacityReserveBytes
            )
            guard !overflow else {
                throw StoreError.downloadTooLarge(maximumBytes: maximumDownloadBytes)
            }
            if let availableCapacity = capacityProvider(destination),
                availableCapacity < requiredCapacity
            {
                throw StoreError.insufficientStorage(
                    requiredBytes: requiredCapacity,
                    availableBytes: availableCapacity
                )
            }
        }
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
            .networkConnectionLost,
            .cannotConnectToHost,
            .notConnectedToInternet,
            .dnsLookupFailed,
            .resourceUnavailable:
            true
        default:
            false
        }
    }

    private static func availableCapacity(at destination: URL) -> Int64? {
        let path = destination.deletingLastPathComponent().path
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
            let number = attributes[.systemFreeSize] as? NSNumber
        else {
            return nil
        }
        return number.int64Value
    }
}
