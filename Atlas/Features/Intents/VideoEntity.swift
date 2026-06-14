import AppIntents
import Foundation
import PipedKit

/// A video exposed to Siri / App Intents. Carries just enough to play, download,
/// or describe a video without another network round-trip. Backs both the
/// parameterized intents ("Play this", "Download this") and — on iOS 27 — the
/// on-screen awareness annotations on the feed, where Siri resolves "this" to the
/// entity the user is looking at.
struct VideoEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Video")
    static let defaultQuery = VideoEntityQuery()

    /// The YouTube video id — also the Spotlight item / on-screen selection id.
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

    init(id: String, title: String, uploader: String?,
         thumbnail: String?, localFileName: String? = nil) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.thumbnail = thumbnail
        self.localFileName = localFileName
    }

    init(_ item: StreamItem) {
        self.init(id: item.videoID ?? item.url, title: item.displayTitle,
                  uploader: item.uploaderName, thumbnail: item.thumbnail)
    }

    init(_ download: DownloadedVideo) {
        self.init(id: download.videoID, title: download.title, uploader: download.uploader,
                  thumbnail: download.thumbnailURL?.absoluteString, localFileName: download.fileName)
    }
}

/// In-memory cache of videos currently visible in the UI, so the entity query can
/// resolve an on-screen selection id back to a full `VideoEntity` without hitting
/// the network. The feed records its items here as they appear.
@MainActor
final class VisibleVideoRegistry {
    static let shared = VisibleVideoRegistry()

    private var byID: [String: VideoEntity] = [:]
    private var order: [String] = []
    private let cap = 250

    func record(_ items: [StreamItem]) {
        for item in items {
            guard let id = item.videoID else { continue }
            if byID[id] == nil { order.append(id) }
            byID[id] = VideoEntity(item)
        }
        while order.count > cap {
            byID.removeValue(forKey: order.removeFirst())
        }
    }

    func entity(for id: String) -> VideoEntity? { byID[id] }
}

/// Resolves `VideoEntity` ids — first from what's on screen, then from downloads.
struct VideoEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [VideoEntity.ID]) async throws -> [VideoEntity] {
        identifiers.compactMap { id in
            if let visible = VisibleVideoRegistry.shared.entity(for: id) { return visible }
            return IntentDataStore.downloads(ids: [id]).first.map(VideoEntity.init)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [VideoEntity] {
        IntentDataStore.downloads(limit: 12).map(VideoEntity.init)
    }
}
