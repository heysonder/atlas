import Foundation
import Security

/// Consent requires both the device-only Keychain item and an installation file
/// excluded from backup. This also protects a restore onto the same device.
@MainActor
protocol SyncInstallationIdentityStoring {
    func existingIdentity() throws -> String?
    func identityForConsent() throws -> String
}

@MainActor
protocol SyncInstallationKeychainStoring {
    func read() throws -> String?
    func write(_ identity: String) throws
}

struct SyncInstallationIdentity: SyncInstallationIdentityStoring {
    private let markerURL: URL
    private let keychain: any SyncInstallationKeychainStoring
    private static var cachedWriterIdentity: String?

    init(
        markerURL: URL? = nil,
        keychain: any SyncInstallationKeychainStoring = SyncInstallationKeychain()
    ) {
        self.markerURL =
            markerURL
            ?? URL.applicationSupportDirectory
            .appendingPathComponent("AtlasSyncInstallation", isDirectory: true)
            .appendingPathComponent("installation-id")
        self.keychain = keychain
    }

    /// Temporary file/Keychain unavailability must never block ordinary local
    /// edits. `nil` tells the journal to keep its persisted writer identity rather
    /// than introducing a throwaway writer. The identity is read once per process.
    static func writerIdentity() -> String? {
        if let cachedWriterIdentity { return cachedWriterIdentity }
        let identity = try? SyncInstallationIdentity().identityForConsent()
        cachedWriterIdentity = identity
        return identity
    }

    func existingIdentity() throws -> String? {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return nil }
        let values = try markerURL.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= 128,
            let marker = String(data: try Data(contentsOf: markerURL), encoding: .utf8),
            UUID(uuidString: marker) != nil
        else { return nil }
        guard let secureMarker = try keychain.read(), marker == secureMarker else { return nil }
        return marker
    }

    func identityForConsent() throws -> String {
        if let existing = try existingIdentity() { return existing }
        let identity = UUID().uuidString
        var directory = markerURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var exclusion = URLResourceValues()
        exclusion.isExcludedFromBackup = true
        try directory.setResourceValues(exclusion)
        try Data(identity.utf8).write(
            to: markerURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        var file = markerURL
        try file.setResourceValues(exclusion)
        // If either write fails, the pair is invalid and consent cannot resume.
        // Only this marker directory is excluded; the user's library is unchanged.
        try keychain.write(identity)
        return identity
    }
}

struct SyncInstallationKeychain: SyncInstallationKeychainStoring {
    private let service = "sh.cmf.atlas.cloud-sync.installation"
    private let account = "device-consent-v1"

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
            let data = result as? Data,
            let identity = String(data: data, encoding: .utf8),
            UUID(uuidString: identity) != nil
        else { throw SyncIdentityError.unavailable }
        return identity
    }

    func write(_ identity: String) throws {
        let updates: [String: Any] = [
            kSecValueData as String: Data(identity.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SyncIdentityError.unavailable }
        let attributes = baseQuery.merging(updates) { _, new in new }
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecDuplicateItem {
            guard SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary) == errSecSuccess else {
                throw SyncIdentityError.unavailable
            }
        } else if added != errSecSuccess {
            throw SyncIdentityError.unavailable
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

enum SyncIdentityError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Atlas could not securely verify this device’s sync consent. Unlock the device and try again."
    }
}
