import Foundation
import Testing

@testable import PipedKit

@Test func decodesChannelTabs() throws {
    let json = """
        {
          "id": "UCchannel",
          "name": "Example",
          "nextpage": "videos-token",
          "tabs": [
            {"name": "shorts", "data": "{\\"url\\":\\"https://www.youtube.com/UCchannel/shorts\\"}"},
            {"name": "playlists", "data": "{\\"url\\":\\"https://www.youtube.com/UCchannel/playlists\\"}"}
          ],
          "relatedStreams": [
            {"url": "/watch?v=long", "type": "stream", "title": "Long video", "isShort": false}
          ]
        }
        """.data(using: .utf8)!

    let channel = try JSONDecoder().decode(Channel.self, from: json)
    let tabs = try #require(channel.tabs)
    #expect(tabs.count == 2)
    #expect(tabs[0].name == "shorts")
    #expect(tabs[0].data?.contains("/shorts") == true)
}

@Test func decodesChannelTabContent() throws {
    let json = """
        {
          "content": [
            {"url": "/watch?v=short", "type": "stream", "title": "Short", "isShort": true}
          ],
          "nextpage": "shorts-token"
        }
        """.data(using: .utf8)!

    let page = try JSONDecoder().decode(ChannelTabPage.self, from: json)
    let content = try #require(page.content)
    #expect(content.count == 1)
    #expect(content[0].videoID == "short")
    #expect(content[0].isShort == true)
    #expect(page.nextPage == "shorts-token")
}

@Test func decodesChannelRelatedStreamsLossily() throws {
    let json = """
        {
          "id": "UCchannel",
          "name": "Example",
          "subscriberCount": 42,
          "relatedStreams": [
            {"url": "/watch?v=good1", "type": "stream", "title": "Good"},
            {"url": null},
            {"url": "/watch?v=good2", "type": "stream", "title": "Also good"}
          ]
        }
        """.data(using: .utf8)!

    let channel = try JSONDecoder().decode(Channel.self, from: json)
    #expect(channel.id == "UCchannel")
    #expect(channel.subscriberCount == 42)
    #expect(channel.relatedStreams?.compactMap(\.videoID) == ["good1", "good2"])
}

@Test func decodesChannelTabContentLossily() throws {
    let json = """
        {
          "content": [
            {"url": "/watch?v=short1", "type": "stream", "title": "Short", "isShort": true},
            {"isShort": "yes"},
            {"url": "/watch?v=short2", "type": "stream", "title": "Short 2", "isShort": true}
          ],
          "nextpage": "shorts-token"
        }
        """.data(using: .utf8)!

    let page = try JSONDecoder().decode(ChannelTabPage.self, from: json)
    #expect(page.content?.compactMap(\.videoID) == ["short1", "short2"])
    #expect(page.nextPage == "shorts-token")
}
