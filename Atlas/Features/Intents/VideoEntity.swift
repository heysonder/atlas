import AppIntents
import Foundation
import PipedKit

/// A video exposed to Siri / App Intents. Carries just enough to play, download,
/// or describe a video without another network round-trip. Backs parameterized
/// intents and Shortcuts workflows that pass a video entity between actions.
struct VideoEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Video")
    static let defaultQuery = VideoEntityQuery()

    /// The YouTube video id, also used in Spotlight and entity resolution.
    let id: String
    let title: String
    let uploader: String?
    /// Remote poster URL, when known (used for the display thumbnail).
    let thumbnail: String?
    /// Set when this id is a completed download, so intents can play it offline.
    let localFileName: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: uploader.map { "\($0)" })
    }

    init(
        id: String, title: String, uploader: String?,
        thumbnail: String?, localFileName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.thumbnail = thumbnail
        self.localFileName = localFileName
    }

    init(_ item: StreamItem) {
        self.init(
            id: item.videoID ?? item.url, title: item.displayTitle,
            uploader: item.uploaderName, thumbnail: item.thumbnail)
    }

    init(_ download: DownloadedVideo) {
        self.init(
            id: download.videoID, title: download.title, uploader: download.uploader,
            thumbnail: download.thumbnailURL?.absoluteString, localFileName: download.fileName)
    }
}

/// In-memory cache of videos recently surfaced in the UI, so an entity query can
/// resolve a known identifier back to a full `VideoEntity` without hitting the
/// network. Lists record their items here as they appear.
@MainActor
final class VisibleVideoRegistry {
    static let shared = VisibleVideoRegistry()

    private var byID: [String: VideoEntity] = [:]
    private var order: [String] = []
    private var byteCostByID: [String: Int] = [:]
    private var totalByteCost = 0
    private let cap: Int
    private let byteCap: Int

    static let maximumIDBytes = 256
    static let maximumTitleBytes = 4 * 1_024
    static let maximumUploaderBytes = 1 * 1_024
    static let maximumURLBytes = 4 * 1_024

    init(cap: Int = 250, byteCap: Int = 512 * 1_024) {
        self.cap = max(1, cap)
        self.byteCap = max(1, byteCap)
    }

    func record(_ items: [StreamItem]) {
        for item in items {
            guard let id = item.videoID else { continue }
            record(
                VideoEntity(
                    id: id, title: item.displayTitle,
                    uploader: item.uploaderName, thumbnail: item.thumbnail))
        }
    }

    func record(_ entity: VideoEntity) {
        guard let bounded = Self.bounded(entity) else { return }
        let cost = Self.byteCost(of: bounded)
        guard cost <= byteCap else { return }

        if let previousCost = byteCostByID[bounded.id] {
            totalByteCost -= previousCost
        } else {
            order.append(bounded.id)
        }
        byID[bounded.id] = bounded
        byteCostByID[bounded.id] = cost
        totalByteCost += cost

        while order.count > cap || totalByteCost > byteCap {
            removeOldest()
        }
    }

    func entity(for id: String) -> VideoEntity? { byID[id] }

    private func removeOldest() {
        guard !order.isEmpty else { return }
        let id = order.removeFirst()
        byID.removeValue(forKey: id)
        totalByteCost -= byteCostByID.removeValue(forKey: id) ?? 0
    }

    private static func bounded(_ entity: VideoEntity) -> VideoEntity? {
        guard !entity.id.isEmpty,
            entity.id.utf8.count <= maximumIDBytes
        else { return nil }
        return VideoEntity(
            id: entity.id,
            title: entity.title.utf8Prefix(maximumTitleBytes),
            uploader: entity.uploader?.utf8Prefix(maximumUploaderBytes),
            thumbnail: boundedURL(entity.thumbnail),
            localFileName: boundedURL(entity.localFileName))
    }

    private static func boundedURL(_ value: String?) -> String? {
        guard let value, value.utf8.count <= maximumURLBytes else { return nil }
        return value
    }

    private static func byteCost(of entity: VideoEntity) -> Int {
        entity.id.utf8.count + entity.title.utf8.count
            + (entity.uploader?.utf8.count ?? 0)
            + (entity.thumbnail?.utf8.count ?? 0)
            + (entity.localFileName?.utf8.count ?? 0)
    }
}

extension String {
    fileprivate func utf8Prefix(_ maximumBytes: Int) -> String {
        guard utf8.count > maximumBytes else { return self }
        var end = startIndex
        var bytes = 0
        while end < endIndex {
            let next = index(after: end)
            let width = self[end..<next].utf8.count
            guard bytes + width <= maximumBytes else { break }
            bytes += width
            end = next
        }
        return String(self[..<end])
    }
}

/// Resolves `VideoEntity` ids from what's on screen and from downloads, and —
/// because it's an `EntityStringQuery` — lets Siri resolve a *described* video by
/// running a search. That's what makes "add a SwiftUI tutorial to Watch Later"
/// work: Siri fills the video parameter by searching, then hands it to the
/// add-to-playlist intent.
struct VideoEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [VideoEntity.ID]) async throws -> [VideoEntity] {
        identifiers.compactMap { id in
            if let visible = VisibleVideoRegistry.shared.entity(for: id) { return visible }
            return IntentDataStore.downloads(ids: [id]).first.map(VideoEntity.init)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [VideoEntity] {
        await IntentDataStore.searchVideos(string, limit: 10)
    }

    @MainActor
    func suggestedEntities() async throws -> [VideoEntity] {
        IntentDataStore.downloads(limit: 12).map(VideoEntity.init)
    }
}
