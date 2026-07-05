import Foundation
import Testing
@testable import Atlas
import PipedKit

@MainActor
@Test func timestampPreviewIndexPrefersLatestActiveTimestamp() throws {
    let comments = try [
        comment("first", text: "Early note at 0:04"),
        comment("second", text: "Better match at 0:08"),
        comment("third", text: "Later note at 0:30"),
    ].map(CommentDisplay.init)
    var index = TimestampCommentPreviewIndex()
    index.updateIfNeeded(comments)

    #expect(index.activeComment(at: 9)?.id == "second")
    #expect(index.activeComment(at: 18) == nil)
    #expect(index.activeComment(at: 35)?.id == "third")
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
