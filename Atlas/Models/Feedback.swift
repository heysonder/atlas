import Foundation
import PipedKit
import SwiftData

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

    init(
        videoID: String, signal: Int, title: String, uploader: String? = nil,
        category: String? = nil, tags: [String]? = nil, createdAt: Date = .now
    ) {
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
@MainActor
enum FeedbackStore {
    /// The current signal for a video (0 when there's no feedback).
    static func signal(for videoID: String, in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Feedback>(predicate: #Predicate { $0.videoID == videoID })
        return (try? context.fetch(descriptor).first)?.signal ?? 0
    }

    /// Set the feedback for a list item (category/tags unknown from a card).
    @discardableResult
    static func set(_ signal: Int, for item: StreamItem, in context: ModelContext) -> Bool {
        guard let id = item.videoID else { return false }
        return set(
            signal, videoID: id, title: item.displayTitle,
            uploader: item.uploaderName, category: nil, tags: nil, in: context)
    }

    /// Set the feedback for a fully-resolved video (category/tags known).
    @discardableResult
    static func set(
        _ signal: Int, videoID: String, title: String, uploader: String?,
        category: String?, tags: [String]?, in context: ModelContext
    ) -> Bool {
        do {
            guard signal == -1 || signal == 0 || signal == 1 else { return false }
            if signal != 0 {
                try PersistedMetadataPolicy.requireIdentifier(videoID, field: "feedback.videoID")
                try PersistedMetadataPolicy.requireText(title, field: "feedback.title")
                try PersistedMetadataPolicy.requireOptionalText(uploader, field: "feedback.uploader")
                try PersistedMetadataPolicy.requireOptionalText(category, field: "feedback.category")
                try PersistedMetadataPolicy.requireTags(tags, field: "feedback.tags")
            }
            let descriptor = FetchDescriptor<Feedback>(predicate: #Predicate { $0.videoID == videoID })
            let existing = try context.fetch(descriptor).first
            if signal != 0, existing == nil {
                guard
                    try context.fetchCount(FetchDescriptor<Feedback>())
                        < PersistedMetadataPolicy.maximumFeedback,
                    PersistedMetadataCapacity.allowsAddingTopLevelRecord(in: context)
                else { return false }
            }
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                if signal == 0 {
                    try LibraryDeletionJournal.record(
                        kind: .feedback, entityID: videoID, in: context)
                    if let existing { context.delete(existing) }
                } else if let existing {
                    existing.signal = signal
                    existing.title = title
                    existing.uploader = uploader
                    if let category { existing.category = category }
                    if let tags { existing.tags = tags }
                    existing.createdAt = .now
                } else {
                    context.insert(
                        Feedback(
                            videoID: videoID, signal: signal, title: title,
                            uploader: uploader, category: category, tags: tags))
                }
                if signal != 0 {
                    try LibrarySyncJournal.capture(kind: .feedback, entityID: videoID, in: context)
                }
            }
            return true
        } catch { return false }
    }

    @discardableResult
    static func clear(in context: ModelContext) -> Bool {
        do {
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                try LibrarySyncJournal.clear(kind: .feedback, in: context)
            }
            return true
        } catch { return false }
    }
}
