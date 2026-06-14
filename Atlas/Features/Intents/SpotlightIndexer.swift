import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Publishes downloads and watch history to Spotlight so they're findable from
/// the lock screen / home search — and, for downloads, fully offline. Tapping a
/// result hands `RootView` an `NSUserActivity` whose identifier we parse back into
/// a video id to resume playback.
///
/// This is the classic CoreSpotlight path that runs on iOS 26+. On iOS 27 the
/// same entities are *also* pushed into the semantic index via `IndexedEntity`
/// (see `VideoEntity`), which adds meaning-based matching on top of keywords.
@MainActor
enum SpotlightIndexer {
    /// Spotlight item ids are namespaced so the tap handler can tell where a hit
    /// came from and so re-indexing one source never clobbers the other.
    static let downloadDomain = "com.chasemarshall.atlas.downloads"
    static let historyDomain = "com.chasemarshall.atlas.history"

    private static func itemID(_ videoID: String) -> String { "video:\(videoID)" }

    /// Extracts the video id from a Spotlight item identifier (or returns it
    /// unchanged if it wasn't namespaced — defensive against older indexes).
    static func videoID(fromItemID id: String) -> String {
        id.hasPrefix("video:") ? String(id.dropFirst("video:".count)) : id
    }

    // MARK: Building items

    private static func attributes(title: String, uploader: String?,
                                   thumbnailURL: URL?) -> CSSearchableItemAttributeSet {
        let attrs = CSSearchableItemAttributeSet(contentType: .movie)
        attrs.title = title
        attrs.contentDescription = uploader
        if let uploader { attrs.keywords = [uploader] }
        attrs.thumbnailURL = thumbnailURL   // local file → poster shows in results
        return attrs
    }

    private static func item(videoID: String, title: String, uploader: String?,
                             thumbnailURL: URL?, domain: String) -> CSSearchableItem {
        CSSearchableItem(uniqueIdentifier: itemID(videoID),
                         domainIdentifier: domain,
                         attributeSet: attributes(title: title, uploader: uploader,
                                                  thumbnailURL: thumbnailURL))
    }

    // MARK: Incremental updates

    static func index(download: DownloadedVideo) {
        let item = item(videoID: download.videoID, title: download.title,
                        uploader: download.uploader, thumbnailURL: download.thumbnailURL,
                        domain: downloadDomain)
        CSSearchableIndex.default().indexSearchableItems([item])
    }

    static func remove(videoID: String) {
        CSSearchableIndex.default()
            .deleteSearchableItems(withIdentifiers: [itemID(videoID)])
    }

    // MARK: Full reindex (launch)

    /// Rebuilds the whole index from the current store. Cheap (CoreSpotlight
    /// dedupes by identifier) and keeps Spotlight honest after edits made while
    /// the app wasn't running to receive incremental updates.
    static func reindexAll() {
        let downloads = IntentDataStore.downloads()
        let history = IntentDataStore.recentHistory()

        var items = downloads.map {
            item(videoID: $0.videoID, title: $0.title, uploader: $0.uploader,
                 thumbnailURL: $0.thumbnailURL, domain: downloadDomain)
        }
        // History rows for videos we've also downloaded are already covered by the
        // download item (which plays offline) — don't index them twice.
        let downloadedIDs = Set(downloads.map(\.videoID))
        for entry in history where !downloadedIDs.contains(entry.videoID) {
            let thumb = entry.thumbnailURL.flatMap(URL.init(string:))
            items.append(item(videoID: entry.videoID, title: entry.title,
                              uploader: entry.uploader, thumbnailURL: thumb,
                              domain: historyDomain))
        }
        CSSearchableIndex.default().indexSearchableItems(items)
    }
}
