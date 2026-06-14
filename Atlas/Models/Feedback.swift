import Foundation
import SwiftData
import PipedKit

/// Explicit taste feedback for a video: "Suggest more" (+1) or "Suggest less"
/// (−1). Stores enough of the video's signature (uploader, YouTube category,
/// creator tags) for the recommender to push more/less of *that kind*, not just
/// hide the one video. Category/tags are filled in when known (the info card has
/// the resolved `VideoDetail`); a card long-press records what the list item has.
@Model
final class Feedback {
    @Attribute(.unique) var videoID: String
    /// +1 = suggest more, −1 = suggest less.
    var signal: Int
    var title: String
    var uploader: String?
    var category: String?
    var tags: [String]?
    var createdAt: Date

    init(videoID: String, signal: Int, title: String, uploader: String? = nil,
         category: String? = nil, tags: [String]? = nil, createdAt: Date = .now) {
        self.videoID = videoID
        self.signal = signal
        self.title = title
        self.uploader = uploader
        self.category = category
        self.tags = tags
        self.createdAt = createdAt
    }
}

/// Single entry point for reading/writing feedback, so the card menu and the
/// info sheet stay consistent. `signal` is the desired end state:
/// +1 / −1 set it, `0` clears it (the toggle-off case).
enum FeedbackStore {
    /// The current signal for a video (0 when there's no feedback).
    static func signal(for videoID: String, in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Feedback>(predicate: #Predicate { $0.videoID == videoID })
        return (try? context.fetch(descriptor).first)?.signal ?? 0
    }

    /// Set the feedback for a list item (category/tags unknown from a card).
    static func set(_ signal: Int, for item: StreamItem, in context: ModelContext) {
        guard let id = item.videoID else { return }
        set(signal, videoID: id, title: item.displayTitle,
            uploader: item.uploaderName, category: nil, tags: nil, in: context)
    }

    /// Set the feedback for a fully-resolved video (category/tags known).
    static func set(_ signal: Int, videoID: String, title: String, uploader: String?,
                    category: String?, tags: [String]?, in context: ModelContext) {
        let descriptor = FetchDescriptor<Feedback>(predicate: #Predicate { $0.videoID == videoID })
        let existing = try? context.fetch(descriptor).first
        guard signal != 0 else {                       // toggle-off → clear
            if let existing { context.delete(existing) }
            return
        }
        if let existing {
            existing.signal = signal
            existing.title = title
            existing.uploader = uploader
            if let category { existing.category = category }   // keep richer data once known
            if let tags { existing.tags = tags }
            existing.createdAt = .now
        } else {
            context.insert(Feedback(videoID: videoID, signal: signal, title: title,
                                    uploader: uploader, category: category, tags: tags))
        }
    }
}
