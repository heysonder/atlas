import Foundation
import PipedKit
import Testing

@testable import Atlas

@MainActor
@Test func timestampPreviewIndexPrefersLatestActiveTimestamp() throws {
    let comments = try [
        comment("first", text: "Early note at 0:04"),
        comment("second", text: "Better match at 0:08"),
        comment("third", text: "Later note at 0:30"),
    ]
    let displays = CommentWorkBudget.displays(
        from: comments,
        identityScope: "test",
        remainingCount: CommentWorkBudget.maximumComments,
        remainingBytes: CommentWorkBudget.maximumAggregateBytes
    ).items
    let index = TimestampCommentPreviewIndex(comments: displays)

    #expect(index.activeComment(at: 9)?.plainText == "Better match at 0:08")
    #expect(index.activeComment(at: 18) == nil)
    #expect(index.activeComment(at: 35)?.plainText == "Later note at 0:30")
}

private func comment(_ id: String, text: String) throws -> PipedKit.Comment {
    let json = """
        {
          "commentId": "\(id)",
          "commentText": "\(text)",
          "author": "Tester"
        }
        """.data(using: .utf8)!
    return try JSONDecoder().decode(PipedKit.Comment.self, from: json)
}
