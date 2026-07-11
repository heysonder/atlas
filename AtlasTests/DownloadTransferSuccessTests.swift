import Foundation
import PipedKit
import Testing

@testable import Atlas

@Test func httpByteContentRangeStrictlyParsesSatisfiedAndUnsatisfiedRanges() throws {
    let satisfied = try #require(HTTPByteContentRange(headerValue: "bytes 0-99/200"))
    #expect(satisfied.range == 0...99)
    #expect(satisfied.totalByteCount == 200)
    #expect(satisfied.range.flatMap(HTTPByteContentRange.byteCount) == 100)

    let unsatisfied = try #require(HTTPByteContentRange(headerValue: "bytes */200"))
    #expect(unsatisfied.range == nil)
    #expect(unsatisfied.totalByteCount == 200)

    let unknownTotal = try #require(HTTPByteContentRange(headerValue: "bytes 4-7/*"))
    #expect(unknownTotal.range == 4...7)
    #expect(unknownTotal.totalByteCount == nil)
}

@Test func streamedDownloadAcceptsCoherentContentRangeAndCompletesProgress() async throws {
    let (root, destination, remoteURL, client) = try makeDownloadTestContext()
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data([1, 2, 3])
    let progress = DownloadProgressRecorder()

    try await DownloadStore.downloadStreaming(
        remoteURL,
        to: destination,
        client: client,
        root: root,
        capacityProvider: { _ in Int64.max },
        streamer: downloadTestStreamer { _ in
            (
                payload,
                downloadTestResponse(
                    url: remoteURL,
                    status: 206,
                    headers: ["Content-Range": "bytes 0-2/3"])
            )
        },
        onProgress: progress.record)

    #expect(try Data(contentsOf: destination) == payload)
    #expect(progress.values.last == 1)
}

@Test func streamedDownloadRetainsWholeBody200Compatibility() async throws {
    let (root, destination, remoteURL, client) = try makeDownloadTestContext()
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data([4, 5, 6, 7])

    try await DownloadStore.downloadStreaming(
        remoteURL,
        to: destination,
        client: client,
        root: root,
        capacityProvider: { _ in Int64.max },
        streamer: downloadTestStreamer { _ in
            (
                payload,
                downloadTestResponse(
                    url: remoteURL,
                    status: 200,
                    headers: ["Content-Length": "\(payload.count)"])
            )
        },
        onProgress: { _ in })

    #expect(try Data(contentsOf: destination) == payload)
}

@Test func streamedDownloadAcceptsRangeIgnoringBodyBeyondBufferedClientLimit() async throws {
    let (root, destination, remoteURL, client) = try makeDownloadTestContext()
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data((0..<96).map(UInt8.init))

    try await DownloadStore.downloadStreaming(
        remoteURL,
        to: destination,
        client: client,
        root: root,
        capacityProvider: { _ in Int64.max },
        streamer: { _, _, maximumBytes, onResponse, onData in
            guard maximumBytes == DownloadStore.maximumDownloadBytes else {
                throw DownloadStore.StoreError.downloadTooLarge(maximumBytes: maximumBytes)
            }
            let response = downloadTestResponse(
                url: remoteURL,
                status: 200,
                headers: ["Content-Length": "\(payload.count)"])
            try onResponse(response)
            for chunkStart in stride(from: 0, to: payload.count, by: 7) {
                let end = min(chunkStart + 7, payload.count)
                _ = try onData(payload.subdata(in: chunkStart..<end))
            }
            return PolicyStreamResult(
                response: response,
                receivedByteCount: Int64(payload.count))
        },
        onProgress: { _ in })

    #expect(try Data(contentsOf: destination) == payload)
}

private nonisolated final class ShortRangeDownloadScript: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    let payload = Data([10, 11, 12, 13, 14, 15])

    var calls: Int { lock.withLock { callCount } }

    func transfer(
        request: URLRequest,
        client: PolicyHTTPClient,
        maximumBytes: Int64,
        onResponse: @escaping @Sendable (URLResponse) throws -> Void,
        onData: @escaping @Sendable (Data) throws -> PolicyStreamDisposition
    ) async throws -> PolicyStreamResult {
        _ = client
        _ = maximumBytes
        let index = lock.withLock {
            defer { callCount += 1 }
            return callCount
        }
        let start = index * 2
        guard start < payload.count, let url = request.url else {
            throw URLError(.badServerResponse)
        }
        let end = start + 1
        let response = downloadTestResponse(
            url: url,
            status: 206,
            headers: ["Content-Range": "bytes \(start)-\(end)/\(payload.count)"])
        let chunk = payload.subdata(in: start..<(end + 1))
        try onResponse(response)
        _ = try onData(chunk)
        return PolicyStreamResult(
            response: response,
            receivedByteCount: Int64(chunk.count))
    }
}

@Test func streamedDownloadContinuesAfterSmaller206RangesWhenTotalHasMoreBytes() async throws {
    let (root, destination, remoteURL, client) = try makeDownloadTestContext()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = ShortRangeDownloadScript()

    try await DownloadStore.downloadStreaming(
        remoteURL,
        to: destination,
        client: client,
        root: root,
        capacityProvider: { _ in Int64.max },
        streamer: script.transfer,
        onProgress: { _ in })

    #expect(try Data(contentsOf: destination) == script.payload)
    #expect(script.calls == 3)
}

@Test func streamedDownloadBoundsUnknownTotalProgressUntilProvenEOF() async throws {
    let (root, destination, remoteURL, client) = try makeDownloadTestContext()
    defer { try? FileManager.default.removeItem(at: root) }
    let progress = DownloadProgressRecorder()

    try await DownloadStore.downloadStreaming(
        remoteURL,
        to: destination,
        client: client,
        root: root,
        capacityProvider: { _ in Int64.max },
        streamer: downloadTestStreamer { request in
            if request.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=0-") == true {
                return (
                    Data([1, 2, 3]),
                    downloadTestResponse(
                        url: remoteURL,
                        status: 206,
                        headers: ["Content-Range": "bytes 0-2/*"])
                )
            }
            return (
                Data(),
                downloadTestResponse(
                    url: remoteURL,
                    status: 416,
                    headers: ["Content-Range": "bytes */3"])
            )
        },
        onProgress: progress.record)

    #expect(progress.values.count == 2)
    #expect(progress.values[0] >= 0 && progress.values[0] < 1)
    #expect(progress.values[1] == 1)
}

private nonisolated final class DownloadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []

    var values: [Double] {
        lock.withLock { storedValues }
    }

    func record(_ value: Double) {
        lock.withLock { storedValues.append(value) }
    }
}
