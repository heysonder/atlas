import Foundation
import Testing

@testable import PipedKit

@Test func canonicalModelPropertiesPreservePipedWireKeys() throws {
    let decoder = JSONDecoder()

    let item = try decoder.decode(
        StreamItem.self,
        from: Data(#"{"url":"/watch?v=video","uploaderUrl":"/channel/creator"}"#.utf8))
    #expect(item.uploaderURL == "/channel/creator")
    #expect(try encodedObject(item)["uploaderUrl"] as? String == "/channel/creator")

    let stream = try decoder.decode(
        PipedKit.MediaStream.self,
        from: Data(#"{"audioTrackId":"en-original"}"#.utf8))
    #expect(stream.audioTrackID == "en-original")
    #expect(try encodedObject(stream)["audioTrackId"] as? String == "en-original")

    let detail = try decoder.decode(
        VideoDetail.self,
        from: Data(
            #"{"uploaderUrl":"/channel/creator","thumbnailUrl":"https://example.com/thumb.jpg"}"#.utf8))
    #expect(detail.uploaderURL == "/channel/creator")
    #expect(detail.thumbnailURL == "https://example.com/thumb.jpg")
    let encodedDetail = try encodedObject(detail)
    #expect(encodedDetail["uploaderUrl"] as? String == "/channel/creator")
    #expect(encodedDetail["thumbnailUrl"] as? String == "https://example.com/thumb.jpg")

    let channel = try decoder.decode(
        Channel.self,
        from: Data(
            #"{"avatarUrl":"https://example.com/avatar.jpg","bannerUrl":"https://example.com/banner.jpg","nextpage":"channel-token"}"#
                .utf8))
    #expect(channel.avatarURL == "https://example.com/avatar.jpg")
    #expect(channel.bannerURL == "https://example.com/banner.jpg")
    #expect(channel.nextPage == "channel-token")
    let encodedChannel = try encodedObject(channel)
    #expect(encodedChannel["avatarUrl"] as? String == "https://example.com/avatar.jpg")
    #expect(encodedChannel["bannerUrl"] as? String == "https://example.com/banner.jpg")
    #expect(encodedChannel["nextpage"] as? String == "channel-token")

    let comments = try decoder.decode(
        CommentsPage.self,
        from: Data(
            #"{"comments":[{"commentId":"comment","commentorUrl":"/channel/commenter"}],"nextpage":"comment-token"}"#
                .utf8))
    let comment = try #require(comments.comments?.first)
    #expect(comment.commentID == "comment")
    #expect(comment.commenterURL == "/channel/commenter")
    #expect(comments.nextPage == "comment-token")
    let encodedComments = try encodedObject(comments)
    #expect(encodedComments["nextpage"] as? String == "comment-token")
    let encodedComment = try #require((encodedComments["comments"] as? [[String: Any]])?.first)
    #expect(encodedComment["commentId"] as? String == "comment")
    #expect(encodedComment["commentorUrl"] as? String == "/channel/commenter")

    let search = try decoder.decode(
        SearchResponse.self,
        from: Data(#"{"nextpage":"search-token"}"#.utf8))
    #expect(search.nextPage == "search-token")
    #expect(try encodedObject(search)["nextpage"] as? String == "search-token")

    let instance = try decoder.decode(
        PipedInstance.self,
        from: Data(#"{"name":"Example","api_url":"https://piped.example"}"#.utf8))
    #expect(instance.apiURL == "https://piped.example")
    #expect(try encodedObject(instance)["api_url"] as? String == "https://piped.example")
}

private func encodedObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
