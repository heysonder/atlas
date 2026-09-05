import Foundation
import PipedKit

/// Fills in channel avatars for feed rows whose items don't carry one (Piped's
/// related-streams and search rows often omit `uploaderAvatar`). Avatars seen
/// on any row are remembered per channel id, so most rows resolve without a
/// request; the rest fetch `/channel/:id` with a small concurrency cap and a
/// negative cache, so a feed of unknown channels can't stampede the instance.
actor ChannelAvatarResolver {
    static let shared = ChannelAvatarResolver()

    private static let defaultsKey = "channelAvatars.v1"
    private static let maximumPersisted = 600
    private static let negativeCacheTTL: TimeInterval = 10 * 60
    private static let maximumConcurrentFetches = 2

    private var known: [String: String]
    private var failedAt: [String: Date] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]
    private var active = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        known = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    func cached(_ channelID: String) -> String? { known[channelID] }

    /// Remember an avatar that arrived with a row, so later rows for the same
    /// channel never need a request.
    func record(channelID: String, avatarURL: String?) {
        guard let avatarURL, !avatarURL.isEmpty, known[channelID] != avatarURL else { return }
        known[channelID] = avatarURL
        persist()
    }

    /// Cached avatar, or one fetched from the instance. Nil when unknown and
    /// the fetch failed (retried after `negativeCacheTTL`).
    func avatar(for channelID: String, client: PipedClient) async -> String? {
        if let hit = known[channelID] { return hit }
        if let failed = failedAt[channelID], Date().timeIntervalSince(failed) < Self.negativeCacheTTL {
            return nil
        }
        if let task = inFlight[channelID] { return await task.value }
        guard active < Self.maximumConcurrentFetches else { return nil }
        active += 1
        let task = Task<String?, Never> {
            let avatar = (try? await client.channel(id: channelID))?.avatarURL
            return avatar.flatMap { $0.isEmpty ? nil : $0 }
        }
        inFlight[channelID] = task
        let result = await task.value
        inFlight[channelID] = nil
        active -= 1
        if let result {
            known[channelID] = result
            failedAt[channelID] = nil
            persist()
        } else {
            failedAt[channelID] = Date()
        }
        return result
    }

    private func persist() {
        if known.count > Self.maximumPersisted {
            // Drop an arbitrary slice; the map has no recency, and refetching is cheap.
            for key in known.keys.prefix(known.count - Self.maximumPersisted) {
                known.removeValue(forKey: key)
            }
        }
        defaults.set(known, forKey: Self.defaultsKey)
    }
}
