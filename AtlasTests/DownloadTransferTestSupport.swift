import Foundation
import PipedKit

@testable import Atlas

func makeDownloadTestContext() throws -> (URL, URL, URL, PolicyHTTPClient) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("atlas-download-transfer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("safeID.video.mp4")
    let remoteURL = URL(string: "https://media.example.test/video")!
    let policy = NetworkDestinationPolicy(resolver: HostAddressResolver { _ in ["93.184.216.34"] })
    let networkContext = try InstanceNetworkContext(
        instanceURL: URL(string: "https://piped.example.test")!,
        policy: policy)
    return (root, destination, remoteURL, PolicyHTTPClient(context: networkContext))
}

nonisolated func downloadTestResponse(
    url: URL,
    status: Int,
    headers: [String: String]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers)!
}

typealias DownloadTestFetch =
    @Sendable (URLRequest) async throws
    -> (Data, HTTPURLResponse)

nonisolated func downloadTestStreamer(
    _ fetch: @escaping DownloadTestFetch
) -> DownloadStore.ChunkStreamer {
    { request, _, _, onResponse, onData in
        let (data, response) = try await fetch(request)
        try onResponse(response)
        if !data.isEmpty {
            _ = try onData(data)
        }
        return PolicyStreamResult(
            response: response,
            receivedByteCount: Int64(data.count)
        )
    }
}
