import Foundation
import Testing

@testable import PipedKit

@Test func decodesSearchItemsLossily() throws {
    let json = """
        {
          "items": [
            {"url": "/watch?v=good1", "type": "stream", "title": "Good"},
            {"title": "missing url"},
            {"url": "/watch?v=good2", "type": "stream", "title": "Also good"}
          ],
          "nextpage": "token",
          "corrected": false
        }
        """.data(using: .utf8)!

    let response = try JSONDecoder().decode(SearchResponse.self, from: json)
    #expect(response.items?.compactMap(\.videoID) == ["good1", "good2"])
    #expect(response.nextPage == "token")
    #expect(response.corrected == false)
}
