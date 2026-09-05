import AppIntents
import CoreSpotlight
import Foundation
import PipedKit
import os

/// A subscribed channel exposed to Siri, Shortcuts, and Spotlight. Typing a creator's name in Spotlight surfaces this row with their
/// avatar; tapping it runs `OpenChannelIntent`, which deep-links into the app.
struct ChannelEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Channel")
    static let defaultQuery = ChannelEntityQuery()

    /// The YouTube channel id (`UC…`).
    let id: String
    @Property(title: "Name") var name: String
    /// Remote avatar URL, when known.
    let avatarURL: String?

    var displayRepresentation: DisplayRepresentation {
        // Spotlight only renders images it can read without the app running, so
        // prefer the on-disk copy written by `ChannelAvatarFileCache`; fall back
        // to the remote URL (works for Siri / Shortcuts UI) or a placeholder.
        let image: DisplayRepresentation.Image?
        if let local = ChannelAvatarFileCache.existingFile(for: id) {
            image = .init(url: local)
        } else if let remote = avatarURL.flatMap(URL.init(string:)) {
            image = .init(url: remote)
        } else {
            image = .init(systemName: "person.crop.circle")
        }
        return DisplayRepresentation(title: "\(name)", subtitle: "Channel", image: image)
    }

    /// The Spotlight row for this channel. Classic `CSSearchableItem` (not
    /// `IndexedEntity`) because the entity-donation pipeline silently fails
    /// where the semantic store is unavailable; the entity is *associated* so
    /// Siri / Shortcuts still get it, and tapping the row routes through
    /// `SpotlightIndexer.itemID`.
    func searchableItem() -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .content)
        attrs.title = name
        attrs.displayName = name
        attrs.contentDescription = "Channel"
        attrs.keywords = [name, "channel", "creator", "subscription"]
        attrs.thumbnailURL = ChannelAvatarFileCache.existingFile(for: id)
            ?? avatarURL.flatMap(URL.init(string:))
        attrs.rankingHint = 1
        let item = CSSearchableItem(
            uniqueIdentifier: SpotlightIndexer.itemID(channel: id),
            domainIdentifier: SpotlightIndexer.channelDomain,
            attributeSet: attrs)
        // Deliberately NOT associateAppEntity: that routes the row through the
        // semantic-store donation, which fails outright (nothing indexed) when
        // that service is unavailable (simulator, Apple Intelligence off).
        // Taps are routed via CSSearchableItemActionType instead.
        return item
    }

    init(id: String, name: String, avatarURL: String?) {
        self.id = id
        self.avatarURL = avatarURL
        self.name = name
    }

    init(_ channel: SubscribedChannel) {
        self.init(id: channel.channelID, name: channel.name, avatarURL: channel.avatarURL)
    }
}

/// Resolves channels by id and by spoken/typed name, so "Open <creator> in Atlas"
/// matches a subscription and Spotlight can rank subscribed channels.
struct ChannelEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [ChannelEntity.ID]) async throws -> [ChannelEntity] {
        let ids = Set(identifiers)
        return IntentDataStore.subscribedChannels()
            .filter { ids.contains($0.channelID) }
            .map(ChannelEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ChannelEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return IntentDataStore.subscribedChannels()
            .filter { $0.name.localizedCaseInsensitiveContains(needle) }
            .map(ChannelEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ChannelEntity] {
        IntentDataStore.subscribedChannels().map(ChannelEntity.init)
    }
}

/// Keeps a small on-disk copy of each subscribed channel's avatar so Spotlight
/// can show it (Spotlight reads thumbnails from the filesystem, not the network,
/// and must work while the app isn't running). Lives in Application Support so
/// it survives cache purges but isn't backed up as user content.
nonisolated enum ChannelAvatarFileCache {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("channel-avatars", isDirectory: true)
    }()

    /// Channel ids are `UC…` alphanumerics, but sanitize anyway before using one
    /// as a file name.
    private static func fileURL(for channelID: String) -> URL {
        let safe = channelID.unicodeScalars
            .filter { CharacterSet.alphanumerics.union(.init(charactersIn: "-_")).contains($0) }
        return directory.appendingPathComponent(String(String.UnicodeScalarView(safe)) + ".img")
    }

    static func existingFile(for channelID: String) -> URL? {
        let url = fileURL(for: channelID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Downloads the avatar (through the app's policy-aware client) and writes it
    /// to disk. No-op when already cached. Failures are silent: the entity falls
    /// back to the remote URL / placeholder.
    static func store(channelID: String, avatarURL: String?) async {
        guard existingFile(for: channelID) == nil,
            let avatarURL, let url = URL(string: avatarURL)
        else { return }
        let client = await MainActor.run { (try? IntentDataStore.app?.httpClient) ?? AppModel.publicHTTPClient }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        let data: Data
        do {
            let (body, response) = try await client.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !body.isEmpty else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                Logger(subsystem: "sh.cmf.atlas", category: "spotlight").error("avatar fetch bad response (\(status)) for \(channelID) from \(url.host() ?? "?")")
                return
            }
            data = body
        } catch {
            Logger(subsystem: "sh.cmf.atlas", category: "spotlight").error("avatar fetch failed for \(channelID): \(error)")
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: channelID), options: .atomic)
    }

    static func remove(channelID: String) {
        try? FileManager.default.removeItem(at: fileURL(for: channelID))
    }

    /// Drops files for channels no longer subscribed.
    static func prune(keeping channelIDs: Set<String>) {
        let keep = Set(channelIDs.map { fileURL(for: $0).lastPathComponent })
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !keep.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}
