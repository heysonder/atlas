import AVFoundation
import Foundation
import PipedKit
import UniformTypeIdentifiers

nonisolated final class PolicyMediaResponseReceiver: @unchecked Sendable {
    struct Outcome {
        let statusCode: Int
        let deliveredBytes: Int64
        let totalBytes: Int64?
        let reachedEnd: Bool
    }

    private let loadingRequest: AVAssetResourceLoadingRequest
    private let requestedRange: ClosedRange<Int64>
    private let requestsAllDataToEnd: Bool
    private let informationOnly: Bool
    private var statusCode = 0
    private var expectedBodyBytes: Int64?
    private var totalBytes: Int64?
    private var deliveredBytes: Int64 = 0
    private var reachedEnd = false

    init(
        loadingRequest: AVAssetResourceLoadingRequest,
        requestedRange: ClosedRange<Int64>,
        requestsAllDataToEnd: Bool,
        informationOnly: Bool
    ) {
        self.loadingRequest = loadingRequest
        self.requestedRange = requestedRange
        self.requestsAllDataToEnd = requestsAllDataToEnd
        self.informationOnly = informationOnly
    }

    func receive(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard let responseURL = response.url ?? loadingRequest.request.url else {
            throw NetworkPolicyError.invalidURL
        }
        if response.mimeType?.lowercased().contains("mpegurl") == true {
            throw PolicyMediaResourceLoader.Control.retryAsManifest
        }

        switch http.statusCode {
        case 206:
            guard let contentRange = HTTPByteContentRange(http),
                let range = contentRange.range,
                range.lowerBound == requestedRange.lowerBound,
                range.upperBound <= requestedRange.upperBound,
                let bodyBytes = HTTPByteContentRange.byteCount(of: range)
            else {
                throw PolicyMediaAssetFactory.MediaError.invalidRange
            }
            if let totalByteCount = contentRange.totalByteCount {
                guard totalByteCount > range.upperBound,
                    totalByteCount <= PolicyMediaAssetFactory.maximumMediaBytes
                else {
                    throw totalByteCount > PolicyMediaAssetFactory.maximumMediaBytes
                        ? PolicyMediaAssetFactory.MediaError.mediaTooLarge(
                            maximumBytes: PolicyMediaAssetFactory.maximumMediaBytes)
                        : PolicyMediaAssetFactory.MediaError.invalidRange
                }
                totalBytes = totalByteCount
            }
            if http.expectedContentLength >= 0,
                http.expectedContentLength != bodyBytes
            {
                throw PolicyMediaAssetFactory.MediaError.invalidRange
            }
            expectedBodyBytes = bodyBytes
        case 200:
            guard requestedRange.lowerBound == 0 else {
                throw PolicyMediaAssetFactory.MediaError.invalidRange
            }
            if http.expectedContentLength >= 0 {
                guard http.expectedContentLength <= PolicyMediaAssetFactory.maximumMediaBytes else {
                    throw PolicyMediaAssetFactory.MediaError.mediaTooLarge(
                        maximumBytes: PolicyMediaAssetFactory.maximumMediaBytes)
                }
                totalBytes = http.expectedContentLength
            }
        case 416:
            guard let contentRange = HTTPByteContentRange(http),
                contentRange.range == nil,
                contentRange.totalByteCount == requestedRange.lowerBound
            else {
                throw PolicyMediaAssetFactory.MediaError.invalidRange
            }
            totalBytes = contentRange.totalByteCount
            reachedEnd = true
        default:
            throw URLError(.badServerResponse)
        }
        statusCode = http.statusCode
        loadingRequest.response = response
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = Self.contentType(
                mimeType: response.mimeType,
                url: responseURL,
                allowed: information.allowedContentTypes)
            if let totalBytes { information.contentLength = totalBytes }
            information.isByteRangeAccessSupported =
                http.statusCode == 206
                || http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        }
    }

    func receive(data: Data) throws -> PolicyStreamDisposition {
        guard statusCode != 416 else { return .stopLoading }
        if informationOnly { return .stopLoading }

        let remaining: Int64
        if statusCode == 206 {
            guard let expectedBodyBytes else {
                throw PolicyMediaAssetFactory.MediaError.invalidRange
            }
            remaining = expectedBodyBytes - deliveredBytes
        } else if requestsAllDataToEnd {
            remaining = PolicyMediaAssetFactory.maximumMediaBytes - deliveredBytes
        } else {
            guard let requestedBytes = HTTPByteContentRange.byteCount(of: requestedRange) else {
                throw PolicyMediaAssetFactory.MediaError.invalidRange
            }
            remaining = requestedBytes - deliveredBytes
        }
        guard remaining >= 0 else { throw PolicyMediaAssetFactory.MediaError.invalidRange }
        let acceptedCount = min(Int64(data.count), remaining)
        if acceptedCount > 0 {
            loadingRequest.dataRequest?.respond(with: data.prefix(Int(acceptedCount)))
            deliveredBytes += acceptedCount
        }
        if statusCode == 206, Int64(data.count) > acceptedCount {
            throw PolicyMediaAssetFactory.MediaError.invalidRange
        }
        if statusCode == 200, !requestsAllDataToEnd, acceptedCount < Int64(data.count) {
            return .stopLoading
        }
        if statusCode == 200, !requestsAllDataToEnd,
            deliveredBytes == HTTPByteContentRange.byteCount(of: requestedRange)
        {
            return .stopLoading
        }
        return .continueLoading
    }

    func finish() throws -> Outcome {
        if informationOnly {
            return Outcome(
                statusCode: statusCode,
                deliveredBytes: 0,
                totalBytes: totalBytes,
                reachedEnd: reachedEnd)
        }
        if let expectedBodyBytes, deliveredBytes != expectedBodyBytes {
            throw PolicyMediaAssetFactory.MediaError.invalidRange
        }
        if statusCode == 200, requestsAllDataToEnd,
            let totalBytes, deliveredBytes != totalBytes
        {
            throw URLError(.networkConnectionLost)
        }
        if statusCode == 200, totalBytes == nil,
            let information = loadingRequest.contentInformationRequest
        {
            information.contentLength = deliveredBytes
        }
        return Outcome(
            statusCode: statusCode,
            deliveredBytes: deliveredBytes,
            totalBytes: totalBytes,
            reachedEnd: reachedEnd)
    }

    static func contentType(
        mimeType: String?,
        url: URL,
        allowed: [String]?
    ) -> String? {
        let proposed =
            mimeType.flatMap { UTType(mimeType: $0)?.identifier }
            ?? UTType(filenameExtension: url.pathExtension)?.identifier
        guard let allowed, !allowed.isEmpty else { return proposed }
        return proposed.flatMap { allowed.contains($0) ? $0 : nil }
    }
}
