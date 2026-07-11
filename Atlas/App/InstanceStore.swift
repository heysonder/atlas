import Foundation
import PipedKit
import Security
import os

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
            !value.isEmpty
        else { return nil }
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
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
            if updateStatus != errSecSuccess {
                // Non-fatal: defaults still holds the value and load() re-mirrors
                // it to the keychain on a later launch.
                Logger(subsystem: "sh.cmf.atlas", category: "instance")
                    .error("keychain update failed (\(updateStatus))")
            }
        }
    }

    func clearInstanceURL() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
            secureStore.loadInstanceURL(),
        ].compactMap { $0 }

        if let resolved =
            candidates
            .map(Self.normalize)
            .first(where: Self.isValidInstanceURL)
        {
            save(resolved)
            return resolved
        }

        // Only wipe storage when a stored value was actually read and found
        // invalid. When nothing could be read at all (e.g. the keychain is
        // unavailable before first unlock), leave both copies untouched so the
        // saved instance survives to the next load.
        if !candidates.isEmpty {
            clear()
        }
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
            !lower.hasPrefix("https://")
        {
            return value
        }
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            value = "https://" + value
        }
        return value
    }

    static func isValidInstanceURL(_ raw: String) -> Bool {
        guard let url = URL(string: normalize(raw)) else { return false }
        return (try? InstanceNetworkContext(instanceURL: url)) != nil
    }
}
