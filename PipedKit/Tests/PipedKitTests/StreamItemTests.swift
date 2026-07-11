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
