import Foundation

public struct PolicyHTTPClient: Sendable {
    public let context: InstanceNetworkContext
    private let transport: PolicySessionTransport
    private let maximumResponseBytes: Int64

    public init(
        context: InstanceNetworkContext,
        configuration: URLSessionConfiguration = .ephemeral,
        maximumResponseBytes: Int64 = 32 * 1_024 * 1_024
    ) {
        self.context = context
        transport = PolicySessionTransport(configuration: configuration)
        self.maximumResponseBytes = max(maximumResponseBytes, 0)
    }

    public func data(from url: URL) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url))
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, maximumResponseBytes: maximumResponseBytes)
    }

    public func data(
        for request: URLRequest,
        maximumResponseBytes: Int64
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw NetworkPolicyError.invalidURL }
        try context.validate(url)
        return try await transport.data(
            request: request,
            context: context,
            maximumResponseBytes: max(maximumResponseBytes, 0))
    }

    public func stream(
        for request: URLRequest,
        maximumResponseBytes: Int64,
        onResponse: @escaping @Sendable (URLResponse) throws -> Void = { _ in },
        onData: @escaping @Sendable (Data) throws -> PolicyStreamDisposition
    ) async throws -> PolicyStreamResult {
        guard let url = request.url else { throw NetworkPolicyError.invalidURL }
        try context.validate(url)
        return try await transport.stream(
            request: request,
            context: context,
            maximumResponseBytes: max(maximumResponseBytes, 0),
            onResponse: onResponse,
            onData: onData)
    }

    var sessionIdentity: ObjectIdentifier { transport.sessionIdentity }
}

public enum PolicyStreamDisposition: Sendable {
    case continueLoading
    case stopLoading
}

public struct PolicyStreamResult: @unchecked Sendable {
    public let response: URLResponse
    public let receivedByteCount: Int64

    public init(response: URLResponse, receivedByteCount: Int64) {
        self.response = response
        self.receivedByteCount = receivedByteCount
    }
}
