import Foundation
import PipedKit

enum ChannelLiveStreamDetector {
    /// A live tab is reverse chronological, so checking a small leading set is
    /// enough without turning every channel visit into a batch of stream extracts.
    private static let maximumResolutionCandidates = 3

    static func candidates(from items: [StreamItem]) -> [StreamItem] {
        Array(
            StreamItemIdentity.firstOccurrences(in: items)
                .filter { $0.isVideo && ($0.isLive || requiresVerification($0)) }
                .prefix(maximumResolutionCandidates))
    }

    static func isActive(_ item: StreamItem, detail: VideoDetail?) -> Bool {
        if item.isLive { return true }
        guard requiresVerification(item), let detail, detail.livestream == true else {
            return false
        }

        let hasHLS =
            detail.hls?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasLiveDuration = detail.duration.map { $0 <= 0 } == true
        return hasHLS || hasLiveDuration
    }

    /// Some older extractor builds use zero instead of -1 for a current live row.
    /// Keep that compatibility check scoped to the livestream tab so ordinary
    /// zero-duration list rows elsewhere do not trigger metadata extraction.
    private static func requiresVerification(_ item: StreamItem) -> Bool {
        item.needsLiveStatusResolution || (item.livestream != true && item.duration == 0)
    }
}
