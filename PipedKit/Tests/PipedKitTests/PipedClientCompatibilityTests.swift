import Foundation
import PipedKit
import Testing

private final class PipedClientCompatibilityURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var stubs: [String: Stub] = [:]

        func set(_ stub: Stub, for url: URL) {
            lock.withLock { stubs[url.absoluteString] = stub }
        }

        func stub(for url: URL) -> Stub? {
            lock.withLock { stubs[url.absoluteString] }
        }

        func removeStub(for url: URL) {
            _ = lock.withLock { stubs.removeValue(forKey: url.absoluteString) }
        }
    }

    private static let registry = Registry()

    static func register(
        url: URL,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data
    ) {
        registry.set(
            Stub(statusCode: statusCode, headers: headers, body: body),
            for: url)
    }

    static func unregister(_ url: URL) {
        registry.removeStub(for: url)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let stub = Self.registry.stub(for: url),
            let client,
            let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client.urlProtocol(self, didLoad: stub.body)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func compatibilityEndpointURL(
    baseURL: URL,
    path: String,
    query: [String: String]
) throws -> URL {
    var components = URLComponents(
        url: baseURL.appendingPathComponent(path),
        resolvingAgainstBaseURL: false)
    components?.queryItems =
        query
        .sorted { $0.key < $1.key }
        .map { URLQueryItem(name: $0.key, value: $0.value) }
    return try #require(components?.url)
}

@Test func compatibilitySessionInitializersHonorCustomProtocolConfiguration() async throws {
    let baseURL = URL(string: "https://93.184.216.34/\(UUID().uuidString)")!
    let trendingURL = try compatibilityEndpointURL(
        baseURL: baseURL,
        path: "trending",
        query: ["region": "US"])
    let suggestionsURL = try compatibilityEndpointURL(
        baseURL: baseURL,
        path: "suggestions",
        query: ["query": "atlas"])
    let instancesURL = URL(string: "https://piped-instances.kavin.rocks/")!
    PipedClientCompatibilityURLProtocol.register(
        url: trendingURL,
        body: Data(#"[{"url":"/watch?v=compat","type":"stream","title":"Compatibility"}]"#.utf8))
    PipedClientCompatibilityURLProtocol.register(
        url: suggestionsURL,
        body: Data(#"["atlas tv"]"#.utf8))
    PipedClientCompatibilityURLProtocol.register(
        url: instancesURL,
        body: Data("[]".utf8))
    defer {
        PipedClientCompatibilityURLProtocol.unregister(trendingURL)
        PipedClientCompatibilityURLProtocol.unregister(suggestionsURL)
        PipedClientCompatibilityURLProtocol.unregister(instancesURL)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PipedClientCompatibilityURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let directClient = PipedClient(baseURL: baseURL, session: session)
    let items = try await directClient.trending()
    #expect(items.map(\.videoID) == ["compat"])

    let stringClient = try #require(
        PipedClient(
            instanceString: baseURL.absoluteString,
            session: session))
    #expect(try await stringClient.suggestions("atlas") == ["atlas tv"])

    #expect(try await PipedClient.fetchInstances(session: session).isEmpty)
}

@Test func compatibilitySessionInitializerRetainsPolicyResponseLimit() async throws {
    let baseURL = URL(string: "https://93.184.216.34/\(UUID().uuidString)")!
    let trendingURL = try compatibilityEndpointURL(
        baseURL: baseURL,
        path: "trending",
        query: ["region": "US"])
    let maximumResponseBytes: Int64 = 32 * 1_024 * 1_024
    PipedClientCompatibilityURLProtocol.register(
        url: trendingURL,
        headers: ["Content-Length": "\(maximumResponseBytes + 1)"],
        body: Data())
    defer { PipedClientCompatibilityURLProtocol.unregister(trendingURL) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PipedClientCompatibilityURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let client = PipedClient(baseURL: baseURL, session: session)
    do {
        _ = try await client.trending()
        Issue.record("Expected compatibility transport to retain the policy response limit")
    } catch {
        #expect(
            error as? NetworkPolicyError
                == .responseTooLarge(maximumBytes: maximumResponseBytes))
    }
}
