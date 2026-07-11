import Foundation
import PipedKit

/// UI-facing comment data with HTML stripping and timestamp extraction done once
/// when comments are loaded, not on every SwiftUI render or playback-time tick.
struct CommentDisplay: Identifiable {
    let id: String
    let plainText: String
    let timestamps: [CommentTimestamp]
    let thumbnail: String?
    let author: String?
    let commentedTime: String?
    let repliesPage: String?
    let hearted: Bool?
    let likeCount: Int?
    let pinned: Bool?
    let verified: Bool?
    let replyCount: Int?
    let byteCost: Int

    init(_ comment: Comment, id: String) {
        let boundedSourceID = CommentWorkBudget.field(comment.id, maximumBytes: 512)
        self.id = id
        author = CommentWorkBudget.optionalField(comment.author, maximumBytes: 512)
        commentedTime = CommentWorkBudget.optionalField(comment.commentedTime, maximumBytes: 256)
        thumbnail = CommentWorkBudget.boundedURL(comment.thumbnail)
        repliesPage = CommentWorkBudget.cursor(comment.repliesPage)
        hearted = comment.hearted
        likeCount = comment.likeCount
        pinned = comment.pinned
        verified = comment.verified
        replyCount = comment.replyCount.map { min(max(0, $0), CommentWorkBudget.maximumComments) }

        let raw = CommentWorkBudget.field(
            comment.commentText ?? "", maximumBytes: CommentWorkBudget.maximumRawTextBytes)
        plainText = CommentWorkBudget.field(
            HTMLText.plain(raw), maximumBytes: CommentWorkBudget.maximumPlainTextBytes)
        timestamps = Array(
            CommentTimestamp.extract(from: plainText)
                .prefix(CommentWorkBudget.maximumTimestampsPerComment))
        byteCost = [boundedSourceID, author, commentedTime, thumbnail, repliesPage, plainText]
            .compactMap { $0 }
            .reduce(0) { $0 + $1.utf8.count }
    }

    var hasReplies: Bool { (replyCount ?? 0) > 0 && repliesPage != nil }
}

enum CommentWorkBudget {
    static let maximumPages = 20
    static let maximumComments = 500
    static let maximumCommentsPerPage = 100
    static let maximumRawTextBytes = 16 * 1_024
    static let maximumPlainTextBytes = 8 * 1_024
    static let maximumTimestampsPerComment = 64
    static let maximumAggregateBytes = 512 * 1_024
    static let maximumCursorBytes = 8 * 1_024
    static let maximumURLBytes = 4 * 1_024

    static func displays(
        from comments: [Comment],
        identityScope: String,
        remainingCount: Int,
        remainingBytes: Int
    ) -> (items: [CommentDisplay], byteCost: Int) {
        var output: [CommentDisplay] = []
        var bytes = 0
        let countLimit = max(0, min(remainingCount, maximumCommentsPerPage))
        let byteLimit = max(0, remainingBytes)
        for (ordinal, comment) in comments.prefix(countLimit).enumerated() {
            let display = CommentDisplay(
                comment,
                id: commentIdentity(
                    sourceID: comment.id,
                    scope: identityScope,
                    ordinal: ordinal))
            guard display.byteCost <= byteLimit - bytes else { continue }
            output.append(display)
            bytes += display.byteCost
        }
        return (output, bytes)
    }

    /// Page scope plus source position makes identity deterministic and unique
    /// even when a partial Piped response repeats or omits `commentId`.
    private static func commentIdentity(
        sourceID: String,
        scope: String,
        ordinal: Int
    ) -> String {
        let boundedScope = field(scope, maximumBytes: 128)
        let boundedSourceID = field(sourceID, maximumBytes: 512)
        return "\(boundedScope)|\(ordinal)|\(boundedSourceID)"
    }

    static func cursor(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            trimmed.utf8.count <= maximumCursorBytes
        else { return nil }
        return trimmed
    }

    static func boundedURL(_ value: String?) -> String? {
        guard let value, value.utf8.count <= maximumURLBytes else { return nil }
        return value
    }

    static func commentCount(_ value: Int?) -> Int {
        guard let value, value >= 0 else { return -1 }
        return min(value, maximumComments)
    }

    static func optionalField(_ value: String?, maximumBytes: Int) -> String? {
        value.map { field($0, maximumBytes: maximumBytes) }
    }

    static func field(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var end = value.startIndex
        var bytes = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let width = value[end..<next].utf8.count
            guard bytes + width <= maximumBytes else { break }
            bytes += width
            end = next
        }
        return String(value[..<end])
    }
}

/// Precomputed lookup for the comment preview that follows timestamp mentions
/// near the playhead. `CommentsLoader` replaces this value only when its comment
/// collection changes; playback-time updates perform binary searches only.
struct TimestampCommentPreviewIndex {
    private struct Entry {
        let comment: CommentDisplay
        let seconds: Int
        let commentIndex: Int
    }

    private let entries: [Entry]
    private let activeWindow = 10

    init(comments: [CommentDisplay]) {
        entries = comments.enumerated().flatMap { index, comment in
            comment.timestamps.map {
                Entry(comment: comment, seconds: $0.seconds, commentIndex: index)
            }
        }
        .sorted {
            if $0.seconds == $1.seconds {
                return $0.commentIndex < $1.commentIndex
            }
            return $0.seconds < $1.seconds
        }
    }

    func activeComment(at playhead: Int) -> CommentDisplay? {
        let upperBound = upperBound(for: playhead)
        guard upperBound > 0 else { return nil }

        let latestSeconds = entries[upperBound - 1].seconds
        guard playhead < latestSeconds + activeWindow else { return nil }

        // Entries with the same timestamp are ordered by source comment index,
        // matching the previous tie-break behavior.
        return entries[lowerBound(for: latestSeconds)].comment
    }

    private func upperBound(for seconds: Int) -> Int {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].seconds <= seconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func lowerBound(for seconds: Int) -> Int {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].seconds < seconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
