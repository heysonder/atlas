import Foundation
import Testing

@testable import PipedKit

@Test func decodesLiveStreamItemsFromListResponses() throws {
    let json = """
        {
          "url": "/watch?v=FuuC4dpSQ1M",
          "type": "stream",
          "title": "Live High-Definition Views from the International Space Station",
          "duration": -1,
          "livestream": true
        }
        """.data(using: .utf8)!

    let item = try JSONDecoder().decode(StreamItem.self, from: json)
    #expect(item.livestream == true)
    #expect(item.isLive)
}

@Test func treatsNegativeListDurationAsNeedingLiveStatusResolutionWhenFlagIsMissing() throws {
    let json = """
        {
          "url": "/watch?v=FuuC4dpSQ1M",
          "type": "stream",
          "title": "Live High-Definition Views from the International Space Station",
          "duration": -1
        }
        """.data(using: .utf8)!

    let item = try JSONDecoder().decode(StreamItem.self, from: json)
    #expect(item.livestream == nil)
    #expect(!item.isLive)
    #expect(item.needsLiveStatusResolution)
}

@Test func treatsStaleFalseLiveFlagAndSentinelDurationAsNeedingResolution() throws {
    let json = """
        {
          "url": "/watch?v=FuuC4dpSQ1M",
          "type": "stream",
          "title": "Possibly live",
          "duration": -1,
          "livestream": false
        }
        """.data(using: .utf8)!

    let item = try JSONDecoder().decode(StreamItem.self, from: json)
    #expect(!item.isLive)
    #expect(item.needsLiveStatusResolution)
}

@Test func endedBroadcastIsNotLive() throws {
    let json = """
        {"url": "/watch?v=abc", "type": "stream", "title": "Ep. 511", "duration": 13850, "livestream": true}
        """.data(using: .utf8)!
    let item = try JSONDecoder().decode(StreamItem.self, from: json)
    #expect(item.livestream == true)
    #expect(!item.isLive)
}

@Test func zeroDurationBroadcastIsLive() throws {
    let json = """
        {"url": "/watch?v=abc", "type": "stream", "title": "Now", "duration": 0, "livestream": true}
        """.data(using: .utf8)!
    let item = try JSONDecoder().decode(StreamItem.self, from: json)
    #expect(item.isLive)
}
