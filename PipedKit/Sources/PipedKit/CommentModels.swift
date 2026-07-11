import Foundation

/// A timestamp mentioned in a comment body, normalized to seconds.
public struct CommentTimestamp: Hashable, Identifiable, Sendable {
    public let seconds: Int
    public let label: String

    public var id: String { "\(seconds)|\(label)" }

    public init(seconds: Int, label: String) {
        self.seconds = seconds
        self.label = label
    }

    public static func extract(from text: String) -> [CommentTimestamp] {
        let pattern = #"(?<![\d:])(?:(\d{1,2}):)?(\d{1,3}):(\d{2})(?![\d:])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                guard range.location != NSNotFound,
                    let swiftRange = Range(range, in: text)
                else { return nil }
                return String(text[swiftRange])
            }

            guard let label = group(0),
                let middleText = group(2),
                let secondsText = group(3),
                let middle = Int(middleText),
                let seconds = Int(secondsText),
                seconds < 60
            else { return nil }

            if let hoursText = group(1), let hours = Int(hoursText) {
                guard middle < 60 else { return nil }
                return CommentTimestamp(
                    seconds: hours * 3_600 + middle * 60 + seconds,
                    label: label)
            }
            return CommentTimestamp(seconds: middle * 60 + seconds, label: label)
        }
    }
}

public struct Comment: Codable, Identifiable, Sendable {
    public let author: String?
    public let thumbnail: String?
    public let commentID: String?
    public let commentText: String?
    public let commentedTime: String?
    public let commenterURL: String?
    public let repliesPage: String?
    public let hearted: Bool?
    public let likeCount: Int?
    public let pinned: Bool?
    public let verified: Bool?
    public let replyCount: Int?
    public let creatorReplied: Bool?

    enum CodingKeys: String, CodingKey {
        case author, thumbnail
        case commentID = "commentId"
        case commentText, commentedTime
        case commenterURL = "commentorUrl"
        case repliesPage, hearted, likeCount, pinned, verified, replyCount, creatorReplied
    }

    @available(*, deprecated, renamed: "commentID")
    public var commentId: String? { commentID }

    @available(*, deprecated, renamed: "commenterURL")
    public var commentorUrl: String? { commenterURL }

    public var id: String {
        commentID ?? "\(author ?? "")|\(commentedTime ?? "")|\(likeCount ?? 0)"
    }

    public var channelID: String? { PipedID.channel(fromURL: commenterURL) }
    public var plainText: String { HTMLText.plain(commentText ?? "") }
    public var timestamps: [CommentTimestamp] { CommentTimestamp.extract(from: plainText) }
    public var hasReplies: Bool { (replyCount ?? 0) > 0 && repliesPage != nil }
}

public struct CommentsPage: Codable, Sendable {
    public let comments: [Comment]?
    public let nextPage: String?
    public let disabled: Bool?
    public let commentCount: Int?

    enum CodingKeys: String, CodingKey {
        case comments
        case nextPage = "nextpage"
        case disabled, commentCount
    }

    public init(comments: [Comment]?, nextPage: String?, disabled: Bool?, commentCount: Int?) {
        self.comments = comments
        self.nextPage = nextPage
        self.disabled = disabled
        self.commentCount = commentCount
    }

    @available(*, deprecated, renamed: "init(comments:nextPage:disabled:commentCount:)")
    public init(comments: [Comment]?, nextpage: String?, disabled: Bool?, commentCount: Int?) {
        self.init(comments: comments, nextPage: nextpage, disabled: disabled, commentCount: commentCount)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.comments = try values.decodeLossyArray([Comment].self, forKey: .comments)
        self.nextPage = try values.decodeIfPresent(String.self, forKey: .nextPage)
        self.disabled = try values.decodeIfPresent(Bool.self, forKey: .disabled)
        self.commentCount = try values.decodeIfPresent(Int.self, forKey: .commentCount)
    }

    @available(*, deprecated, renamed: "nextPage")
    public var nextpage: String? { nextPage }
}
