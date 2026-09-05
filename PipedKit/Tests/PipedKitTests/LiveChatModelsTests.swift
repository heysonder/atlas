import Foundation
import Testing

@testable import PipedKit

@Test func decodesLiveChatPageFromServerResponse() throws {
    let json = """
        {
          "videoId": "GotlA1KKWoo",
          "messages": [
            {
              "id": "msg-1",
              "type": "liveChatTextMessageRenderer",
              "text": "hello from chat",
              "author": "@viewer",
              "authorChannelId": "UCabc",
              "avatar": "https://yt4.ggpht.com/avatar=s64",
              "timestampUsec": "1787458259484040",
              "publishedAt": "2026-08-23T04:10:59.484Z",
              "verified": false,
              "chatOwner": true,
              "chatModerator": false,
              "chatSponsor": true,
              "event": {"message": {"runs": [{"text": "hello from chat"}]}}
            },
            {
              "id": "msg-2",
              "type": "liveChatViewerEngagementMessageRenderer",
              "text": "Welcome to live chat!"
            }
          ],
          "nextPageToken": "token123",
          "pollAfterMs": 10000
        }
        """.data(using: .utf8)!

    let page = try JSONDecoder().decode(LiveChatPage.self, from: json)

    #expect(page.videoId == "GotlA1KKWoo")
    #expect(page.nextPageToken == "token123")
    #expect(page.pollAfterMs == 10_000)

    let messages = try #require(page.messages)
    #expect(messages.count == 2)

    let text = try #require(messages.first)
    #expect(text.isTextMessage)
    #expect(text.text == "hello from chat")
    #expect(text.author == "@viewer")
    #expect(text.avatar == "https://yt4.ggpht.com/avatar=s64")
    #expect(text.timestampMicroseconds == 1_787_458_259_484_040)
    #expect(text.chatOwner == true)
    #expect(text.chatSponsor == true)
    #expect(text.chatModerator == false)

    let engagement = messages[1]
    #expect(!engagement.isTextMessage)
}

@Test func liveChatMessageDecodingSurvivesMalformedSiblings() throws {
    let json = """
        {
          "videoId": "abc",
          "messages": [
            "not an object",
            {"id": "msg-1", "type": "liveChatTextMessageRenderer", "text": "kept"}
          ]
        }
        """.data(using: .utf8)!

    let page = try JSONDecoder().decode(LiveChatPage.self, from: json)
    #expect(page.messages?.map(\.id) == ["msg-1"])
    #expect(page.pollAfterMs == nil)
}

@Test func decodesReplayOffsetsAndTimestampText() throws {
    let json = """
        {
          "videoId": "mOgHUaT1R3M",
          "replay": true,
          "pollAfterMs": 0,
          "nextPageToken": "r1.abc",
          "messages": [
            {
              "id": "m1", "type": "liveChatTextMessageRenderer", "text": "gm",
              "author": "@x", "videoOffsetMs": 3009, "timestampText": "0:03"
            }
          ]
        }
        """.data(using: .utf8)!

    let page = try JSONDecoder().decode(LiveChatPage.self, from: json)
    let message = try #require(page.messages?.first)
    #expect(message.videoOffsetMs == 3009)
    #expect(message.timestampText == "0:03")
    #expect(page.nextPageToken == "r1.abc")
}

@Test func videoDetailDistinguishesLiveNowFromEndedStreams() throws {
    func detail(livestream: Bool = true, duration: Int?, hls: String?) throws -> VideoDetail {
        let json = """
            {"title": "t", "livestream": \(livestream), "duration": \(duration.map(String.init) ?? "null"),
             "hls": \(hls.map { "\"\($0)\"" } ?? "null")}
            """.data(using: .utf8)!
        return try JSONDecoder().decode(VideoDetail.self, from: json)
    }

    let live = try detail(duration: -1, hls: "https://example.com/live.m3u8")
    #expect(live.isCurrentlyLive)

    // Ended broadcasts come back as plain videos: flag off, real duration,
    // and (as observed on real instances) still carrying an HLS manifest.
    let ended = try detail(livestream: false, duration: 14_610, hls: "https://example.com/vod.m3u8")
    #expect(!ended.isCurrentlyLive)
}

@Test func liveChatTimestampFallsBackToNilWhenNotNumeric() throws {
    let message = LiveChatMessage(
        id: "m", type: "liveChatTextMessageRenderer", text: "t", author: "a",
        timestampUsec: "not-a-number")
    #expect(message.timestampMicroseconds == nil)
}
