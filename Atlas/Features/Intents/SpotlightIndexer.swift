import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Publishes downloads and watch history to Spotlight so they're findable from
/// the lock screen / home search — and, for downloads, fully offline. Tapping a
/// result hands `RootView` an `NSUserActivity` whose identifier we parse back into
/// a video id to resume playback.
@MainActor
enum SpotlightIndexer {
    /// Spotlight item ids are namespaced so the tap handler can tell where a hit
    /// came from and so re-indexing one source never clobbers the other.
    static let downloadDomain = "sh.cmf.atlas.downloads"
    static let historyDomain = "sh.cmf.atlas.history"

    /// Domains used before the namespace was unified on the bundle id; purged
    /// once per launch by `reindexAll` so stale items can't linger under them.
    private static let legacyDomains = [
        "com.chasemarshall.atlas.downloads",
        "com.chasemarshall.atlas.history",
    ]

    private static func itemID(_ videoID: String) -> String { "video:\(videoID)" }

    /// Extracts the video id from a Spotlight item identifier (or returns it
    /// unchanged if it wasn't namespaced — defensive against older indexes).
    static func videoID(fromItemID id: String) -> String {
        id.hasPrefix("video:") ? String(id.dropFirst("video:".count)) : id
    }

    // MARK: Building items

    private static func attributes(
        title: String, uploader: String?,
        thumbnailURL: URL?
    ) -> CSSearchableItemAttributeSet {
        let attrs = CSSearchableItemAttributeSet(contentType: .movie)
        attrs.title = title
        attrs.contentDescription = uploader
        if let uploader { attrs.keywords = [uploader] }
        attrs.thumbnailURL = thumbnailURL  // local file → poster shows in results
        return attrs
    }

    private static func item(
        videoID: String, title: String, uploader: String?,
        thumbnailURL: URL?, domain: String
    ) -> CSSearchableItem {
        CSSearchableItem(
            uniqueIdentifier: itemID(videoID),
            domainIdentifier: domain,
            attributeSet: attributes(
                title: title, uploader: uploader,
                thumbnailURL: thumbnailURL))
    }

    // MARK: Incremental updates

    static func index(download: DownloadedVideo) {
        let item = item(
            videoID: download.videoID, title: download.title,
            uploader: download.uploader, thumbnailURL: download.thumbnailURL,
            domain: downloadDomain)
        CSSearchableIndex.default().indexSearchableItems([item])
    }

    static func remove(videoID: String) {
        CSSearchableIndex.default()
            .deleteSearchableItems(withIdentifiers: [itemID(videoID)])
    }

    // MARK: Full reindex (launch)

    /// Rebuilds the owned Spotlight domains from the current store. Deleting the
    /// current and legacy domains first makes the store authoritative: entries
    /// removed while Atlas was not running cannot linger in Spotlight.
    static func reindexAll() {
        let downloads = IntentDataStore.downloads()
        let history = IntentDataStore.recentHistory()

        var items = downloads.map {
            item(
                videoID: $0.videoID, title: $0.title, uploader: $0.uploader,
                thumbnailURL: $0.thumbnailURL, domain: downloadDomain)
        }
        // History rows for videos we've also downloaded are already covered by the
        // download item (which plays offline) — don't index them twice.
        let downloadedIDs = Set(downloads.map(\.videoID))
        for entry in history where !downloadedIDs.contains(entry.videoID) {
            let thumb = entry.thumbnailURL.flatMap(URL.init(string:))
            items.append(
                item(
                    videoID: entry.videoID, title: entry.title,
                    uploader: entry.uploader, thumbnailURL: thumb,
                    domain: historyDomain))
        }
        let ownedDomains = [downloadDomain, historyDomain] + legacyDomains
        Task {
            let index = CSSearchableIndex.default()
            do {
                try await index.deleteSearchableItems(withDomainIdentifiers: ownedDomains)
                guard !Task.isCancelled, !items.isEmpty else { return }
                try await index.indexSearchableItems(items)
            } catch {
                // Derived data only; the next launch retries the authoritative rebuild.
            }
        }
    }
}
