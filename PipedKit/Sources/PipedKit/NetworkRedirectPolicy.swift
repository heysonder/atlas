import Foundation

struct NetworkRedirectPolicy: Sendable {
    let context: InstanceNetworkContext

    func sanitizedRequest(
        responseURL: URL?,
        request: URLRequest
    ) throws -> URLRequest {
        guard let destination = request.url else { throw NetworkPolicyError.invalidURL }
        try context.validate(destination)
        var sanitized = request
        if !Self.sameOrigin(responseURL, destination) {
            sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
            sanitized.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
            sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return sanitized
    }

    private static func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
