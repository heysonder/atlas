import Foundation
import Testing

@testable import PipedKit

@Test func extractsCommentTimestamps() throws {
    let json = """
        {"commentText":"Intro <a>1:23</a><br>Deep dive 1:02:03 and long one 123:45"}
        """.data(using: .utf8)!
    let comment = try JSONDecoder().decode(PipedKit.Comment.self, from: json)
    #expect(comment.timestamps.map { $0.seconds } == [83, 3723, 7425])
    #expect(comment.timestamps.map { $0.label } == ["1:23", "1:02:03", "123:45"])
}

@Test func extractsDescriptionChapterTimestamps() {
    let description = """
        Chapters
        00:00 Intro
        02:15 Setup
        1:03:45 Full walkthrough
        """
    let timestamps = CommentTimestamp.extract(from: description)
    #expect(timestamps.map(\.seconds) == [0, 135, 3825])
    #expect(timestamps.map(\.label) == ["00:00", "02:15", "1:03:45"])
}

@Test func ignoresInvalidCommentTimestamps() throws {
    let json = """
        {"commentText":"Ratios like 16:9, invalid seconds 1:75, and chained 1:02:03:04 are not timestamps."}
        """.data(using: .utf8)!
    let comment = try JSONDecoder().decode(PipedKit.Comment.self, from: json)
    #expect(comment.timestamps.isEmpty)
}

@Test func decodesCommentsLossily() throws {
    let json = """
        {
          "comments": [
            {"author": "a", "commentId": "c1", "commentText": "first", "likeCount": 3},
            {"likeCount": "many"},
            {"author": "b", "commentId": "c2", "commentText": "second"}
          ],
          "nextpage": "token",
          "disabled": false,
          "commentCount": 2
        }
        """.data(using: .utf8)!

    let page = try JSONDecoder().decode(CommentsPage.self, from: json)
    #expect(page.comments?.compactMap(\.commentID) == ["c1", "c2"])
    #expect(page.nextPage == "token")
    #expect(page.disabled == false)
    #expect(page.commentCount == 2)
}
