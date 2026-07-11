import Foundation
import PipedKit
import Testing

@testable import Atlas

@Test func httpByteContentRangeRejectsMalformedAndOverflowingValues() {
    let invalidValues = [
        "items 0-1/2",
        "bytes -1-1/2",
        "bytes 2-1/2",
        "bytes 0-1/-2",
        "bytes 0-1/9223372036854775808",
        "bytes 0/1",
        "bytes 0-1",
    ]
    for value in invalidValues {
        #expect(HTTPByteContentRange(headerValue: value) == nil)
    }

    #expect(HTTPByteContentRange.byteCount(of: 0...Int64.max) == nil)
}

@Test func streamedDownloadCancellationRemovesPartiallyWrittenFile() async throws {
    let (root, destination, remoteURL, client) = try makeDownloadTestContext()
    defer { try? FileManager.default.removeItem(at: root) }
    let task = Task {
        try await DownloadStore.downloadStreaming(
            remoteURL,
            to: destination,
            client: client,
            root: root,
            capacityProvider: { _ in Int64.max },
            streamer: { _, _, _, onResponse, onData in
                let response = downloadTestResponse(
                    url: remoteURL,
                    status: 200,
                    headers: [:])
                try onResponse(response)
                _ = try onData(Data([1, 2, 3]))
                try await Task.sleep(for: .seconds(60))
                return PolicyStreamResult(response: response, receivedByteCount: 3)
            },
            onProgress: { _ in })
    }

    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    do {
        try await task.value
        Issue.record("Expected streamed download cancellation")
    } catch is CancellationError {
        // Expected.
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func streamedDownloadRejectsMismatchedRangeAndRemovesPartialFile() async throws {
    let (root, destination, remoteURL, client) = try makeDownloadTestContext()
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        try await DownloadStore.downloadStreaming(
            remoteURL,
            to: destination,
            client: client,
            root: root,
            capacityProvider: { _ in Int64.max },
            streamer: downloadTestStreamer { _ in
                (
                    Data([1, 2, 3]),
                    downloadTestResponse(
                        url: remoteURL,
                        status: 206,
                        headers: ["Content-Range": "bytes 1-3/4"])
                )
            },
            onProgress: { _ in })
        Issue.record("Expected the mismatched range to fail")
    } catch {
        #expect(error as? DownloadStore.StoreError == .invalidRangeResponse)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func streamedDownloadRejectsHugeDeclaredTotalBeforeWriting() async throws {
    let (root, destination, remoteURL, client) = try makeDownloadTestContext()
    defer { try? FileManager.default.removeItem(at: root) }
    let hugeTotal = DownloadStore.maximumDownloadBytes + 1

    do {
        try await DownloadStore.downloadStreaming(
            remoteURL,
            to: destination,
            client: client,
            root: root,
            capacityProvider: { _ in Int64.max },
            streamer: downloadTestStreamer { _ in
                (
                    Data([1]),
                    downloadTestResponse(
                        url: remoteURL,
                        status: 206,
                        headers: ["Content-Range": "bytes 0-0/\(hugeTotal)"])
                )
            },
            onProgress: { _ in })
        Issue.record("Expected the aggregate download limit to reject the total")
    } catch {
        #expect(
            error as? DownloadStore.StoreError
                == .downloadTooLarge(
                    maximumBytes: DownloadStore.maximumDownloadBytes))
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func streamedDownloadRequiresCapacityReserveBeforeWriting() async throws {
    let (root, destination, remoteURL, client) = try makeDownloadTestContext()
    defer { try? FileManager.default.removeItem(at: root) }
    let available = DownloadStore.minimumFreeCapacityReserveBytes + 2

    do {
        try await DownloadStore.downloadStreaming(
            remoteURL,
            to: destination,
            client: client,
            root: root,
            capacityProvider: { _ in available },
            streamer: downloadTestStreamer { _ in
                (
                    Data([1, 2, 3]),
                    downloadTestResponse(
                        url: remoteURL,
                        status: 206,
                        headers: ["Content-Range": "bytes 0-2/3"])
                )
            },
            onProgress: { _ in })
        Issue.record("Expected the free-capacity reserve to be enforced")
    } catch {
        #expect(
            error as? DownloadStore.StoreError
                == .insufficientStorage(
                    requiredBytes: DownloadStore.minimumFreeCapacityReserveBytes + 3,
                    availableBytes: available))
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func streamedDownloadCancellationBeforeResponseRemovesTheCreatedFile() async throws {
    let (root, destination, remoteURL, client) = try makeDownloadTestContext()
    defer { try? FileManager.default.removeItem(at: root) }
    let task = Task {
        try await DownloadStore.downloadStreaming(
            remoteURL,
            to: destination,
            client: client,
            root: root,
            capacityProvider: { _ in Int64.max },
            streamer: { _, _, _, _, _ in
                try await Task.sleep(for: .seconds(60))
                let response = downloadTestResponse(
                    url: remoteURL,
                    status: 200,
                    headers: [:]
                )
                return PolicyStreamResult(response: response, receivedByteCount: 0)
            },
            onProgress: { _ in })
    }

    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    do {
        try await task.value
        Issue.record("Expected cancellation to leave no partial file")
    } catch is CancellationError {
        // Expected.
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}
