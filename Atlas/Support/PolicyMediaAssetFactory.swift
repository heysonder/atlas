import AVFoundation
import Foundation
import ObjectiveC
import PipedKit

/// Builds AVFoundation assets whose root, redirects, ranges, and nested HLS
/// resources all travel through the same destination policy.
nonisolated enum PolicyMediaAssetFactory {
    private static let secureScheme = "atlas-https"
    private static let localScheme = "atlas-http"
    nonisolated(unsafe) private static var retentionKey: UInt8 = 0

    static let maximumManifestInputBytes = 4 * 1_024 * 1_024
    static let maximumManifestOutputBytes = 8 * 1_024 * 1_024
    static let maximumManifestLines = 20_000
    static let maximumManifestLineBytes = 64 * 1_024
    static let maximumManifestWorkUnits = 50_000
    static let maximumMediaBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    static let mediaChunkBytes: Int64 = 4 * 1_024 * 1_024

    /// An asset AVFoundation loads natively (no custom scheme / resource
    /// loader), after the root URL passes the destination policy. Used for HLS:
    /// routing HLS through the resource-loader proxy broke on-device playback
    /// (AV1 HLS never left "waiting" or lost video — regression from 879a1e8),
    /// and AVPlayer's native HLS pipeline handles playlists, byte ranges, and
    /// ABR itself. Nested playlist/segment hosts are those the instance
    /// advertises; the root is validated here.
    static func nativeAsset(
        for url: URL,
        client: PolicyHTTPClient,
        noCache: Bool = false
    ) throws -> AVURLAsset {
        try client.context.validate(url)
        guard noCache else { return AVURLAsset(url: url) }
        return AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "Cache-Control": "no-cache",
                    "Pragma": "no-cache",
                ]
            ])
    }

    static func asset(
        for url: URL,
        client: PolicyHTTPClient,
        noCache: Bool = false
    ) throws -> AVURLAsset {
        try client.context.validate(url)
        let encoded = try policyURL(for: url)
        let delegate = PolicyMediaResourceLoader(client: client, noCache: noCache)
        let asset = AVURLAsset(url: encoded)
        delegate.attach(to: asset.resourceLoader)
        // AVAssetResourceLoader.delegate is weak. Keep the policy delegate alive
        // exactly as long as its asset without a global cache or leak.
        objc_setAssociatedObject(
            asset,
            &retentionKey,
            delegate,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    static func policyURL(for url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased()
        else {
            throw NetworkPolicyError.invalidURL
        }
        switch scheme {
        case "https": components.scheme = secureScheme
        case "http": components.scheme = localScheme
        default: throw NetworkPolicyError.unsupportedScheme
        }
        guard let result = components.url else { throw NetworkPolicyError.invalidURL }
        return result
    }

    static func originalURL(for url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased()
        else {
            throw NetworkPolicyError.invalidURL
        }
        switch scheme {
        case secureScheme: components.scheme = "https"
        case localScheme: components.scheme = "http"
        default: throw NetworkPolicyError.unsupportedScheme
        }
        guard let result = components.url else { throw NetworkPolicyError.invalidURL }
        return result
    }
}
