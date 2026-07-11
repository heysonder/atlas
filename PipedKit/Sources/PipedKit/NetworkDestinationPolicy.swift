import Darwin
import Foundation

private enum ResolvedAddressScope: Hashable {
    case publicInternet
    case local
    case forbidden
}

public struct NetworkDestinationPolicy: Sendable {
    public let resolver: HostAddressResolver

    public init(resolver: HostAddressResolver = .system) {
        self.resolver = resolver
    }

    public func scopeForConfiguredInstance(_ url: URL) throws -> NetworkTrustScope {
        let parts = try validatedParts(of: url)
        let classification = try classify(host: parts.host, allowUnresolvedPublicName: true)
        switch classification {
        case .local:
            return .localNetwork
        case .publicInternet:
            guard parts.scheme == "https" else { throw NetworkPolicyError.destinationNotAllowed }
            return .publicInternet
        case .forbidden:
            throw NetworkPolicyError.destinationNotAllowed
        }
    }

    public func validate(_ url: URL, scope: NetworkTrustScope) throws {
        let parts = try validatedParts(of: url)
        let classification = try classify(host: parts.host, allowUnresolvedPublicName: false)
        switch (scope, classification, parts.scheme) {
        case (.publicInternet, .publicInternet, "https"):
            return
        case (.localNetwork, .publicInternet, "https"):
            return
        case (.localNetwork, .local, "http"),
            (.localNetwork, .local, "https"):
            return
        default:
            throw NetworkPolicyError.destinationNotAllowed
        }
    }

    private struct URLParts {
        let scheme: String
        let host: String
    }

    private func validatedParts(of url: URL) throws -> URLParts {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased()
        else {
            throw NetworkPolicyError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw NetworkPolicyError.unsupportedScheme
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw NetworkPolicyError.invalidURL
        }
        guard components.user == nil, components.password == nil else {
            throw NetworkPolicyError.credentialsNotAllowed
        }
        if let port = components.port, !(1...65_535).contains(port) {
            throw NetworkPolicyError.invalidPort
        }
        return URLParts(scheme: scheme, host: normalizeHost(host))
    }

    private func classify(
        host: String,
        allowUnresolvedPublicName: Bool
    ) throws -> ResolvedAddressScope {
        if isUnspecifiedHost(host) { throw NetworkPolicyError.destinationNotAllowed }
        if isReservedLocalHost(host) { return .local }
        if let literal = IPAddress(host) { return literal.scope }

        let resolved = try resolver.resolve(host).compactMap(IPAddress.init)
        guard !resolved.isEmpty else {
            if isSingleLabelHost(host), allowUnresolvedPublicName { return .local }
            if allowUnresolvedPublicName { return .publicInternet }
            throw NetworkPolicyError.unresolvedHost
        }
        let scopes = Set(resolved.map(\.scope))
        if scopes.contains(.forbidden) { throw NetworkPolicyError.destinationNotAllowed }
        let hasPublic = scopes.contains(.publicInternet)
        let hasLocal = scopes.contains(.local)
        guard !(hasPublic && hasLocal) else { throw NetworkPolicyError.mixedAddressScope }
        return hasPublic ? .publicInternet : .local
    }

    private func normalizeHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private func isUnspecifiedHost(_ host: String) -> Bool {
        host == "0.0.0.0" || host == "::"
    }

    private func isReservedLocalHost(_ host: String) -> Bool {
        host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host == "home.arpa"
            || host.hasSuffix(".home.arpa")
    }

    private func isSingleLabelHost(_ host: String) -> Bool {
        !host.contains(".") && !host.contains(":")
    }
}

private struct IPAddress {
    private enum Storage {
        case v4(UInt32)
        case v6([UInt8])
    }

    private let storage: Storage

    init?(_ raw: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, raw, &v4) == 1 {
            storage = .v4(UInt32(bigEndian: v4.s_addr))
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, raw, &v6) == 1 {
            storage = .v6(withUnsafeBytes(of: &v6) { Array($0) })
            return
        }
        return nil
    }

    var scope: ResolvedAddressScope {
        switch storage {
        case .v4(let value):
            let a = UInt8((value >> 24) & 0xff)
            let b = UInt8((value >> 16) & 0xff)
            let c = UInt8((value >> 8) & 0xff)
            if a == 10 || a == 127 { return .local }
            if a == 100 && (64...127).contains(b) { return .local }
            if a == 169 && b == 254 { return .local }
            if a == 172 && (16...31).contains(b) { return .local }
            if a == 192 && b == 168 { return .local }
            if a == 0 || a >= 224 { return .forbidden }
            if a == 192 && b == 0 { return .forbidden }
            if a == 198 && (b == 18 || b == 19) { return .forbidden }
            if a == 198 && b == 51 && c == 100 { return .forbidden }
            if a == 203 && b == 0 && c == 113 { return .forbidden }
            return .publicInternet
        case .v6(let bytes):
            guard bytes.count == 16 else { return .forbidden }
            if bytes.allSatisfy({ $0 == 0 }) { return .forbidden }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return .local }
            if bytes[0] == 0xff { return .forbidden }
            if (bytes[0] & 0xfe) == 0xfc { return .local }
            if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return .local }
            if bytes[0...9].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                let value =
                    UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16
                    | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
                return IPAddress(storage: .v4(value)).scope
            }
            // Only globally routable unicast space is public. Documentation and
            // other special-use prefixes inside 2000::/3 are denied below.
            guard (bytes[0] & 0xe0) == 0x20 else { return .forbidden }
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 {
                return .forbidden
            }
            return .publicInternet
        }
    }

    private init(storage: Storage) {
        self.storage = storage
    }
}
