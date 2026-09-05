import CoreSpotlight
import Foundation
import os

/// Publishes subscribed channels, downloads, watch history, and playlists to
/// Spotlight as classic `CSSearchableItem`s with the matching App Entity
/// associated (Apple's recommended pairing; the pure `IndexedEntity` donation
/// path fails silently when the semantic store is unavailable). Tapping a result
/// hands `RootView` an `NSUserActivity` whose identifier we parse back into a
/// typed target via `target(fromItemID:)`.
@MainActor
enum SpotlightIndexer {
    private static let log = Logger(subsystem: "sh.cmf.atlas", category: "spotlight")

    /// Spotlight item ids are namespaced so the tap handler can tell where a hit
    /// came from and so re-indexing one source never clobbers the other.
    nonisolated static let downloadDomain = "sh.cmf.atlas.downloads"
    nonisolated static let historyDomain = "sh.cmf.atlas.history"
    nonisolated static let channelDomain = "sh.cmf.atlas.channels"
    nonisolated static let playlistDomain = "sh.cmf.atlas.playlists"

    /// Domains used before the namespace was unified on the bundle id; purged
    /// once per launch by `reindexAll` so stale items can't linger under them.
    private static let legacyDomains = [
        "com.chasemarshall.atlas.downloads",
        "com.chasemarshall.atlas.history",
    ]

    nonisolated static func itemID(video id: String) -> String { "video:\(id)" }
    nonisolated static func itemID(channel id: String) -> String { "channel:\(id)" }
    nonisolated static func itemID(playlist id: String) -> String { "playlist:\(id)" }

    enum Target: Equatable {
        case video(String)
        case channel(String)
        case playlist(String)
    }

    /// Decodes a tapped Spotlight item id. Un-namespaced ids are treated as
    /// video ids (older indexes).
    static func target(fromItemID id: String) -> Target {
        if id.hasPrefix("channel:") { return .channel(String(id.dropFirst("channel:".count))) }
        if id.hasPrefix("playlist:") { return .playlist(String(id.dropFirst("playlist:".count))) }
        if id.hasPrefix("video:") { return .video(String(id.dropFirst("video:".count))) }
        return .video(id)
    }

    /// Kept for callers that only care about videos.
    static func videoID(fromItemID id: String) -> String {
        if case .video(let v) = target(fromItemID: id) { return v }
        return id
    }

    // MARK: Incremental updates

    static func index(download: DownloadedVideo) {
        let item = VideoEntity(download).searchableItem(domain: downloadDomain)
        Task { try? await CSSearchableIndex.default().indexSearchableItems([item]) }
    }

    static func remove(videoID: String) {
        Task {
            try? await CSSearchableIndex.default()
                .deleteSearchableItems(withIdentifiers: [itemID(video: videoID)])
        }
    }

    // MARK: Channels

    /// Publishes one subscription, fetching its avatar to disk first so the
    /// result row shows the creator's picture.
    static func index(channelID: String, name: String, avatarURL: String?) {
        Task {
            await ChannelAvatarFileCache.store(channelID: channelID, avatarURL: avatarURL)
            let item = ChannelEntity(id: channelID, name: name, avatarURL: avatarURL).searchableItem()
            do {
                try await CSSearchableIndex.default().indexSearchableItems([item])
            } catch {
                log.error("index channel failed: \(error)")
            }
        }
    }

    static func remove(channelID: String) {
        ChannelAvatarFileCache.remove(channelID: channelID)
        Task {
            try? await CSSearchableIndex.default()
                .deleteSearchableItems(withIdentifiers: [itemID(channel: channelID)])
        }
    }

    /// Re-publishes every subscription. Rows are indexed right away (searchable
    /// by name even before avatars arrive), then avatars are fetched a few at a
    /// time and those rows re-indexed with images.
    static func reindexChannels() {
        let snapshot = IntentDataStore.subscribedChannels()
            .map { ChannelEntity(id: $0.channelID, name: $0.name, avatarURL: $0.avatarURL) }
        log.info("reindexChannels: \(snapshot.count) subscriptions")
        Task {
            let index = CSSearchableIndex.default()
            do {
                try await index.deleteSearchableItems(withDomainIdentifiers: [channelDomain])
                guard !snapshot.isEmpty else { return }
                try await index.indexSearchableItems(snapshot.map { $0.searchableItem() })
                log.info("indexed \(snapshot.count) channels")
            } catch {
                log.error("channel reindex failed: \(error)")
            }
            ChannelAvatarFileCache.prune(keeping: Set(snapshot.map(\.id)))
            let missing = snapshot.filter { ChannelAvatarFileCache.existingFile(for: $0.id) == nil }
            guard !missing.isEmpty else { return }
            await withTaskGroup(of: Void.self) { group in
                var pending = missing.makeIterator()
                for _ in 0..<3 {
                    if let e = pending.next() {
                        group.addTask { await ChannelAvatarFileCache.store(channelID: e.id, avatarURL: e.avatarURL) }
                    }
                }
                while await group.next() != nil {
                    if let e = pending.next() {
                        group.addTask { await ChannelAvatarFileCache.store(channelID: e.id, avatarURL: e.avatarURL) }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            let fetched = missing.filter { ChannelAvatarFileCache.existingFile(for: $0.id) != nil }
            log.info("fetched \(fetched.count)/\(missing.count) avatars")
            guard !fetched.isEmpty else { return }
            do {
                try await index.indexSearchableItems(fetched.map { $0.searchableItem() })
            } catch {
                log.error("avatar re-index failed: \(error)")
            }
        }
    }

    // MARK: Full reindex (launch)

    /// Rebuilds every owned domain from the current store. Deleting the current
    /// and legacy domains first makes the store authoritative: entries removed
    /// while Atlas was not running cannot linger in Spotlight.
    static func reindexAll() {
        reindexChannels()
        let downloads = IntentDataStore.downloads()
        let downloadedIDs = Set(downloads.map(\.videoID))
        var items = downloads.map { VideoEntity($0).searchableItem(domain: downloadDomain) }
        // History rows for videos we've also downloaded are already covered by
        // the download item (which plays offline) — don't index them twice.
        for entry in IntentDataStore.recentHistory() where !downloadedIDs.contains(entry.videoID) {
            items.append(VideoEntity(entry).searchableItem(domain: historyDomain))
        }
        items += IntentDataStore.playlists().map { PlaylistEntity($0).searchableItem() }
        let owned = [downloadDomain, historyDomain, playlistDomain] + legacyDomains
        Task {
            let index = CSSearchableIndex.default()
            do {
                try await index.deleteSearchableItems(withDomainIdentifiers: owned)
                guard !Task.isCancelled, !items.isEmpty else { return }
                try await index.indexSearchableItems(items)
                log.info("indexed \(items.count) videos/playlists")
            } catch {
                // Derived data only; the next launch retries the authoritative rebuild.
                log.error("reindexAll failed: \(error)")
            }
        }
    }
}
