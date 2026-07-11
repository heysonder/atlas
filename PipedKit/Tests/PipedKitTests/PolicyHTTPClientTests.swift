import Foundation
import Testing

@testable import PipedKit

private final class PolicyClientTestProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest, URLProtocolClient, URLProtocol) -> Void

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: Handler] = [:]

        func set(_ handler: @escaping Handler, for url: URL) {
            lock.withLock { handlers[url.absoluteString] = handler }
        }

        func handler(for url: URL) -> Handler? {
            lock.withLock { handlers[url.absoluteString] }
        }

        func remove(_ url: URL) {
            _ = lock.withLock { handlers.removeValue(forKey: url.absoluteString) }
        }
    }

    private static let registry = Registry()
    private let stopLock = NSLock()
    private var stopHandler: (() -> Void)?

    static func register(_ handler: @escaping Handler, for url: URL) {
        registry.set(handler, for: url)
    }

    static func unregister(_ url: URL) {
        registry.remove(url)
    }

    func onStop(_ handler: @escaping () -> Void) {
        stopLock.withLock { stopHandler = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let handler = Self.registry.handler(for: url),
            let client
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        handler(request, client, self)
    }

    override func stopLoading() {
        let handler = stopLock.withLock { stopHandler }
        handler?()
    }
}

private final class PolicyClientStopRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int { lock.withLock { storedCount } }

    func record() {
        lock.withLock { storedCount += 1 }
    }
}

private final class PolicyClientDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()

    var data: Data { lock.withLock { storedData } }

    func append(_ data: Data) {
        lock.withLock { storedData.append(data) }
    }
}

private func makePolicyClientTestClient(maximumResponseBytes: Int64) throws -> PolicyHTTPClient {
    let policy = NetworkDestinationPolicy(resolver: HostAddressResolver { _ in ["93.184.216.34"] })
    let context = try InstanceNetworkContext(
        instanceURL: URL(string: "https://public.test")!,
        policy: policy)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PolicyClientTestProtocol.self]
    return PolicyHTTPClient(
        context: context,
        configuration: configuration,
        maximumResponseBytes: maximumResponseBytes)
}

private func registerPolicyClientResponse(
    url: URL,
    headers: [String: String] = [:],
    chunks: [Data]
) {
    PolicyClientTestProtocol.register(
        { _, client, protocolInstance in
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers)!
            client.urlProtocol(
                protocolInstance,
                didReceive: response,
                cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client.urlProtocol(protocolInstance, didLoad: chunk)
            }
            client.urlProtocolDidFinishLoading(protocolInstance)
        }, for: url)
}

@Test func policyHTTPClientAcceptsAnExactSizeResponseWithoutDeclaredLength() async throws {
    let url = URL(string: "https://public.test/exact-\(UUID().uuidString)")!
    registerPolicyClientResponse(url: url, chunks: [Data([0, 1]), Data([2, 3])])
    defer { PolicyClientTestProtocol.unregister(url) }

    let client = try makePolicyClientTestClient(maximumResponseBytes: 4)
    let (data, _) = try await client.data(from: url)

    #expect(data == Data([0, 1, 2, 3]))
}

@Test func policyHTTPClientRejectsTheFirstBytePastItsStreamingLimit() async throws {
    let url = URL(string: "https://public.test/overflow-\(UUID().uuidString)")!
    registerPolicyClientResponse(url: url, chunks: [Data([0, 1, 2, 3]), Data([4])])
    defer { PolicyClientTestProtocol.unregister(url) }

    let client = try makePolicyClientTestClient(maximumResponseBytes: 4)
    do {
        _ = try await client.data(from: url)
        Issue.record("Expected the streaming response limit to reject byte five")
    } catch {
        #expect(error as? NetworkPolicyError == .responseTooLarge(maximumBytes: 4))
    }
}

@Test func policyHTTPClientRejectsAnOversizeDeclaredLengthBeforeTheBody() async throws {
    let url = URL(string: "https://public.test/declared-\(UUID().uuidString)")!
    registerPolicyClientResponse(
        url: url,
        headers: ["Content-Length": "5"],
        chunks: [])
    defer { PolicyClientTestProtocol.unregister(url) }

    let client = try makePolicyClientTestClient(maximumResponseBytes: 4)
    do {
        _ = try await client.data(from: url)
        Issue.record("Expected the declared response length to be rejected")
    } catch {
        #expect(error as? NetworkPolicyError == .responseTooLarge(maximumBytes: 4))
    }
}

@Test func policyHTTPClientCancellationStopsTransportAndCompletesOnce() async throws {
    let url = URL(string: "https://public.test/cancel-\(UUID().uuidString)")!
    let recorder = PolicyClientStopRecorder()
    PolicyClientTestProtocol.register(
        { _, _, protocolInstance in
            (protocolInstance as? PolicyClientTestProtocol)?.onStop(recorder.record)
        }, for: url)
    defer { PolicyClientTestProtocol.unregister(url) }
    let client = try makePolicyClientTestClient(maximumResponseBytes: 4)
    let task = Task { try await client.data(from: url) }

    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Expected cancellation to complete the request exactly once")
    } catch is CancellationError {
        // Expected.
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(recorder.count == 1)
}

@Test func policyHTTPClientReusesItsSessionAndStreamsPastTheBufferedDefault() async throws {
    let bufferedURL = URL(string: "https://public.test/buffered-\(UUID().uuidString)")!
    let streamedURL = URL(string: "https://public.test/streamed-\(UUID().uuidString)")!
    let payload = Data((0..<9).map(UInt8.init))
    let contentLength = String(payload.count)
    let streamedChunks = [
        Data(payload.prefix(3)),
        Data(payload.dropFirst(3).prefix(3)),
        Data(payload.suffix(3)),
    ]
    registerPolicyClientResponse(
        url: bufferedURL,
        headers: ["Content-Length": contentLength],
        chunks: [payload])
    registerPolicyClientResponse(
        url: streamedURL,
        headers: ["Content-Length": contentLength],
        chunks: streamedChunks)
    defer {
        PolicyClientTestProtocol.unregister(bufferedURL)
        PolicyClientTestProtocol.unregister(streamedURL)
    }

    let client = try makePolicyClientTestClient(maximumResponseBytes: 4)
    let session = client.sessionIdentity
    do {
        _ = try await client.data(from: bufferedURL)
        Issue.record("Expected the buffered API's four-byte limit to remain enforced")
    } catch {
        #expect(error as? NetworkPolicyError == .responseTooLarge(maximumBytes: 4))
    }

    let recorder = PolicyClientDataRecorder()
    let result = try await client.stream(
        for: URLRequest(url: streamedURL),
        maximumResponseBytes: 16,
        onData: { data in
            recorder.append(data)
            return .continueLoading
        })

    #expect(recorder.data == payload)
    #expect(result.receivedByteCount == Int64(payload.count))
    #expect(client.sessionIdentity == session)
}

@Test func policyHTTPClientEarlyStreamStopCancelsOnlyThatRequest() async throws {
    let stoppedURL = URL(string: "https://public.test/stopped-\(UUID().uuidString)")!
    let nextURL = URL(string: "https://public.test/next-\(UUID().uuidString)")!
    registerPolicyClientResponse(url: stoppedURL, chunks: [Data([1, 2]), Data([3, 4])])
    registerPolicyClientResponse(url: nextURL, chunks: [Data([9])])
    defer {
        PolicyClientTestProtocol.unregister(stoppedURL)
        PolicyClientTestProtocol.unregister(nextURL)
    }
    let client = try makePolicyClientTestClient(maximumResponseBytes: 8)
    let recorder = PolicyClientDataRecorder()

    _ = try await client.stream(
        for: URLRequest(url: stoppedURL),
        maximumResponseBytes: 8,
        onData: { data in
            recorder.append(data)
            return .stopLoading
        })
    let (next, _) = try await client.data(from: nextURL)

    // URLSession may coalesce protocol chunks into one delegate callback; early
    // stop prevents later callbacks, but cannot split a callback already handed over.
    #expect(recorder.data == Data([1, 2, 3, 4]))
    #expect(next == Data([9]))
}

@Test func policyHTTPClientKeepsConcurrentTaskBodiesIsolatedOnTheSharedSession() async throws {
    let firstURL = URL(string: "https://public.test/first-\(UUID().uuidString)")!
    let secondURL = URL(string: "https://public.test/second-\(UUID().uuidString)")!
    registerPolicyClientResponse(url: firstURL, chunks: [Data([1]), Data([2])])
    registerPolicyClientResponse(url: secondURL, chunks: [Data([8]), Data([9])])
    defer {
        PolicyClientTestProtocol.unregister(firstURL)
        PolicyClientTestProtocol.unregister(secondURL)
    }
    let client = try makePolicyClientTestClient(maximumResponseBytes: 8)

    async let first = client.data(from: firstURL)
    async let second = client.data(from: secondURL)
    let (firstResult, secondResult) = try await (first, second)

    #expect(firstResult.0 == Data([1, 2]))
    #expect(secondResult.0 == Data([8, 9]))
}
