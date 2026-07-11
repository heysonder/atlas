import AVFoundation
import Foundation
import PipedKit

nonisolated final class PolicyMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    enum Control: Error {
        case retryAsManifest
    }

    private let queue = DispatchQueue(
        label: "sh.cmf.atlas.media-policy-loader",
        qos: .userInitiated)
    private let client: PolicyHTTPClient
    private let noCache: Bool
    private let taskLock = NSLock()
    nonisolated(unsafe) private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(client: PolicyHTTPClient, noCache: Bool) {
        self.client = client
        self.noCache = noCache
    }

    func attach(to resourceLoader: AVAssetResourceLoader) {
        resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
            (try? PolicyMediaAssetFactory.originalURL(for: url)) != nil
        else { return false }
        let identifier = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self, weak loadingRequest] in
            guard let self, let loadingRequest else { return }
            await self.load(loadingRequest)
        }
        taskLock.withLock { tasks[identifier] = task }
        Task { [weak self] in
            await task.value
            self?.removeTask(identifier)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        removeTask(ObjectIdentifier(loadingRequest))?.cancel()
    }

    @discardableResult
    private nonisolated func removeTask(
        _ identifier: ObjectIdentifier
    ) -> Task<Void, Never>? {
        taskLock.withLock { tasks.removeValue(forKey: identifier) }
    }

    private func load(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        do {
            guard let policyURL = loadingRequest.request.url else {
                throw NetworkPolicyError.invalidURL
            }
            let originalURL = try PolicyMediaAssetFactory.originalURL(for: policyURL)
            if Self.isManifestURL(originalURL) {
                try await loadManifest(originalURL, into: loadingRequest)
            } else {
                do {
                    try await loadMedia(originalURL, into: loadingRequest)
                } catch Control.retryAsManifest {
                    try await loadManifest(originalURL, into: loadingRequest)
                }
            }
            try Task.checkCancellation()
            if !loadingRequest.isFinished { loadingRequest.finishLoading() }
        } catch is CancellationError {
            return
        } catch {
            if !loadingRequest.isFinished { loadingRequest.finishLoading(with: error) }
        }
    }

    private func loadManifest(
        _ originalURL: URL,
        into loadingRequest: AVAssetResourceLoadingRequest
    ) async throws {
        var request = baseRequest(for: originalURL, loadingRequest: loadingRequest)
        request.setValue(nil, forHTTPHeaderField: "Range")
        let (received, response) = try await client.data(
            for: request,
            maximumResponseBytes: Int64(PolicyMediaAssetFactory.maximumManifestInputBytes))
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        let responseURL = response.url ?? originalURL
        let data = try PolicyMediaAssetFactory.rewriteHLSManifest(received, baseURL: responseURL)
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = PolicyMediaResponseReceiver.contentType(
                mimeType: response.mimeType,
                url: responseURL,
                allowed: information.allowedContentTypes)
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = true
        }
        loadingRequest.response = response
        if let dataRequest = loadingRequest.dataRequest {
            dataRequest.respond(with: Self.manifestPayload(data, request: dataRequest))
        }
    }

    private func loadMedia(
        _ originalURL: URL,
        into loadingRequest: AVAssetResourceLoadingRequest
    ) async throws {
        let dataRequest = loadingRequest.dataRequest
        let start = max(dataRequest?.currentOffset ?? 0, dataRequest?.requestedOffset ?? 0)
        guard start >= 0, start < PolicyMediaAssetFactory.maximumMediaBytes else {
            throw PolicyMediaAssetFactory.MediaError.mediaTooLarge(
                maximumBytes: PolicyMediaAssetFactory.maximumMediaBytes)
        }
        let requestsAll = dataRequest?.requestsAllDataToEndOfResource == true
        let informationOnly = dataRequest == nil
        let requestedBytes = informationOnly ? 1 : Int64(max(dataRequest?.requestedLength ?? 0, 0))
        let remaining: Int64
        if requestsAll {
            remaining = PolicyMediaAssetFactory.maximumMediaBytes - start
        } else {
            let (end, overflow) = start.addingReportingOverflow(requestedBytes)
            guard !overflow, end <= PolicyMediaAssetFactory.maximumMediaBytes else {
                throw PolicyMediaAssetFactory.MediaError.mediaTooLarge(
                    maximumBytes: PolicyMediaAssetFactory.maximumMediaBytes)
            }
            remaining = max(requestedBytes, informationOnly ? 1 : 0)
        }
        guard remaining > 0 else { return }

        var offset = start
        let target = start + remaining
        while offset < target {
            try Task.checkCancellation()
            let range = try PolicyMediaAssetFactory.finiteMediaRange(
                offset: offset,
                remaining: target - offset)
            var request = baseRequest(for: originalURL, loadingRequest: loadingRequest)
            request.setValue(
                "bytes=\(range.lowerBound)-\(range.upperBound)",
                forHTTPHeaderField: "Range")
            let receiver = PolicyMediaResponseReceiver(
                loadingRequest: loadingRequest,
                requestedRange: range,
                requestsAllDataToEnd: requestsAll,
                informationOnly: informationOnly)
            _ = try await client.stream(
                for: request,
                maximumResponseBytes: PolicyMediaAssetFactory.maximumMediaBytes,
                onResponse: receiver.receive,
                onData: receiver.receive)
            let outcome = try receiver.finish()
            if outcome.reachedEnd || outcome.statusCode == 200 || informationOnly { break }
            guard outcome.deliveredBytes > 0 else {
                throw PolicyMediaAssetFactory.MediaError.invalidRange
            }
            let (nextOffset, overflow) = offset.addingReportingOverflow(outcome.deliveredBytes)
            guard !overflow, nextOffset <= PolicyMediaAssetFactory.maximumMediaBytes else {
                throw PolicyMediaAssetFactory.MediaError.mediaTooLarge(
                    maximumBytes: PolicyMediaAssetFactory.maximumMediaBytes)
            }
            offset = nextOffset
            if let totalBytes = outcome.totalBytes, offset >= totalBytes { break }
        }
    }

    private func baseRequest(
        for originalURL: URL,
        loadingRequest: AVAssetResourceLoadingRequest
    ) -> URLRequest {
        var request = URLRequest(url: originalURL)
        request.cachePolicy = noCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        request.timeoutInterval = 90
        let excludedHeaders = ["host", "authorization", "proxy-authorization", "cookie", "range"]
        for (name, value) in loadingRequest.request.allHTTPHeaderFields ?? [:]
        where !excludedHeaders.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private static func isManifestURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8"
            || url.absoluteString.range(of: ".m3u8", options: .caseInsensitive) != nil
    }

    private static func manifestPayload(
        _ data: Data,
        request: AVAssetResourceLoadingDataRequest
    ) -> Data {
        let start = max(request.currentOffset, request.requestedOffset)
        guard start >= 0, start < Int64(data.count) else { return Data() }
        let available = data.count - Int(start)
        let requested =
            request.requestsAllDataToEndOfResource
            ? available
            : min(available, request.requestedLength)
        return data.subdata(in: Int(start)..<(Int(start) + requested))
    }
}
