import Foundation

public enum NetworkTrustScope: Sendable, Equatable {
    case publicInternet
    case localNetwork
}

public enum NetworkPolicyError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL
    case credentialsNotAllowed
    case unsupportedScheme
    case invalidPort
    case unresolvedHost
    case mixedAddressScope
    case destinationNotAllowed
    case redirectLoop
    case tooManyRedirects
    case responseTooLarge(maximumBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The network address is invalid."
        case .credentialsNotAllowed: "Network addresses containing credentials are not allowed."
        case .unsupportedScheme: "Only HTTP and HTTPS network addresses are supported."
        case .invalidPort: "The network address contains an invalid port."
        case .unresolvedHost: "The network destination could not be resolved safely."
        case .mixedAddressScope: "The network destination resolves to mixed public and local addresses."
        case .destinationNotAllowed: "The selected Piped instance is not allowed to access that destination."
        case .redirectLoop: "The network request was stopped because its redirects formed a loop."
        case .tooManyRedirects: "The network request followed too many redirects."
        case .responseTooLarge(let maximumBytes):
            "The network response exceeded the \(maximumBytes) byte safety limit."
        }
    }
}
