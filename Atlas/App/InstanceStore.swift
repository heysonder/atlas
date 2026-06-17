import Foundation
import Security

protocol InstanceSecureStoring {
    func loadInstanceURL() -> String?
    func saveInstanceURL(_ value: String)
    func clearInstanceURL()
}

struct KeychainInstanceStore: InstanceSecureStoring {
    private let service = "sh.cmf.atlas"
    private let account = "piped-instance-url"

    func loadInstanceURL() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    func saveInstanceURL(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updates: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
        }
    }

    func clearInstanceURL() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct InstanceStore {
    static let defaultsKey = "atlas.instanceURL"

    static let live = InstanceStore(defaults: .standard, secureStore: KeychainInstanceStore())

    private let defaults: UserDefaults
    private let secureStore: any InstanceSecureStoring

    init(defaults: UserDefaults, secureStore: any InstanceSecureStoring) {
        self.defaults = defaults
        self.secureStore = secureStore
    }

    func load() -> String {
        let candidates = [
            defaults.string(forKey: Self.defaultsKey),
            secureStore.loadInstanceURL()
        ]

        if let resolved = candidates.compactMap({ $0 })
            .map(Self.normalize)
            .first(where: Self.isValidInstanceURL) {
            save(resolved)
            return resolved
        }

        clear()
        return ""
    }

    func save(_ rawValue: String) {
        let normalized = Self.normalize(rawValue)
        guard Self.isValidInstanceURL(normalized) else {
            clear()
            return
        }

        defaults.set(normalized, forKey: Self.defaultsKey)
        secureStore.saveInstanceURL(normalized)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
        secureStore.clearInstanceURL()
    }

    /// Ensures an instance string is a usable absolute URL:
    /// trims whitespace, drops trailing slashes, and adds `https://` when no scheme is present.
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        while value.hasSuffix("/") { value.removeLast() }
        let lower = value.lowercased()
        if lower.contains("://"),
           !lower.hasPrefix("http://"),
           !lower.hasPrefix("https://") {
            return value
        }
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            value = "https://" + value
        }
        return value
    }

    static func isValidInstanceURL(_ raw: String) -> Bool {
        guard let url = URL(string: normalize(raw)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else { return false }

        switch scheme {
        case "https":
            return true
        case "http":
            return isPlainHTTPAllowedHost(host)
        default:
            return false
        }
    }

    private static func isPlainHTTPAllowedHost(_ host: String) -> Bool {
        var normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        while normalizedHost.hasSuffix(".") {
            normalizedHost.removeLast()
        }

        guard !normalizedHost.isEmpty else { return false }
        if normalizedHost == "localhost" || normalizedHost == "0.0.0.0" {
            return true
        }
        if isPrivateIPv4Host(normalizedHost) || isPrivateIPv6Host(normalizedHost) {
            return true
        }

        return !normalizedHost.contains(".") && !normalizedHost.contains(":")
    }

    private static func isPrivateIPv4Host(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }

        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4,
              octets.allSatisfy({ (0...255).contains($0) }) else { return false }

        let first = octets[0]
        let second = octets[1]
        return first == 10
            || first == 127
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
    }

    private static func isPrivateIPv6Host(_ host: String) -> Bool {
        guard host.contains(":") else { return false }
        if host == "::1" { return true }

        guard let firstSegment = host.split(separator: ":", omittingEmptySubsequences: false).first,
              let firstValue = UInt16(firstSegment, radix: 16) else { return false }

        return (0xfc00...0xfdff).contains(firstValue)
            || (0xfe80...0xfebf).contains(firstValue)
    }
}
