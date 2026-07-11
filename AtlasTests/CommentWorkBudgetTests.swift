import Foundation
import PipedKit
import Testing

@testable import Atlas

@MainActor
@Test func commentBudgetCapsTextTimestampsPageAndAggregateWork() throws {
    let timestampText = Array(repeating: "0:01", count: 200).joined(separator: " ")
    let comment = try decodeComment(id: "one", text: timestampText)
    let display = CommentWorkBudget.displays(
        from: [comment],
        identityScope: "test",
        remainingCount: 1,
        remainingBytes: CommentWorkBudget.maximumAggregateBytes
    ).items[0]
    #expect(display.plainText.utf8.count <= CommentWorkBudget.maximumPlainTextBytes)
    #expect(display.timestamps.count == CommentWorkBudget.maximumTimestampsPerComment)

    let many = try (0..<150).map { index in
        try decodeComment(id: "c\(index)", text: String(repeating: "x", count: 8_000))
    }
    let bounded = CommentWorkBudget.displays(
        from: many,
        identityScope: "test",
        remainingCount: CommentWorkBudget.maximumComments,
        remainingBytes: 20_000)
    #expect(bounded.items.count <= CommentWorkBudget.maximumCommentsPerPage)
    #expect(bounded.byteCost <= 20_000)
    #expect(CommentWorkBudget.cursor(String(repeating: "t", count: 8_193)) == nil)
}

private func decodeComment(id: String, text: String) throws -> PipedKit.Comment {
    let data = try JSONSerialization.data(withJSONObject: [
        "commentId": id,
        "commentText": text,
        "replyCount": 0,
    ])
    return try JSONDecoder().decode(PipedKit.Comment.self, from: data)
}
