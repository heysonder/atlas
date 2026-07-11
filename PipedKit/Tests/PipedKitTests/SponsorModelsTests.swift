import Foundation
import Testing

@testable import PipedKit

@Test func decodesSponsorSegments() throws {
    let json = """
        {"hash":"abcd","segments":[
            {"segment":[10.5,25.25],"category":"sponsor","actionType":"skip","UUID":"u1"},
            {"segment":[100.0,108.0],"category":"selfpromo","actionType":"skip","UUID":"u2"}
        ]}
        """.data(using: .utf8)!
    let res = try JSONDecoder().decode(SponsorSegmentsResponse.self, from: json)
    let segs = try #require(res.segments)
    #expect(segs.count == 2)
    #expect(segs[0].start == 10.5)
    #expect(segs[0].end == 25.25)
    #expect(segs[0].uuid == "u1")
    #expect(segs[0].sponsorCategory == .sponsor)
    #expect(segs[1].sponsorCategory == .selfpromo)
}

@Test func decodesSponsorSegmentsLossily() throws {
    let json = """
        {"segments":[
            {"segment":[10.0,20.0],"category":"sponsor","actionType":"skip","UUID":"good"},
            {"segment":"bad","category":"selfpromo"},
            {"segment":[30.0,40.0],"category":"intro","actionType":"skip","UUID":"also-good"}
        ]}
        """.data(using: .utf8)!
    let res = try JSONDecoder().decode(SponsorSegmentsResponse.self, from: json)
    let segs = try #require(res.segments)
    #expect(segs.map(\.uuid) == ["good", "also-good"])
    #expect(segs.map(\.category) == ["sponsor", "intro"])
}

@Test func decodesNullSponsorSegmentsAsMissing() throws {
    let json = #"{"segments":null}"#.data(using: .utf8)!
    let res = try JSONDecoder().decode(SponsorSegmentsResponse.self, from: json)
    #expect(res.segments == nil)
}

@Test func sponsorCategoryRawValues() {
    #expect(SponsorCategory.musicOfftopic.rawValue == "music_offtopic")
    #expect(SponsorCategory(rawValue: "interaction") == .interaction)
    #expect(SponsorCategory(rawValue: "nonsense") == nil)
    #expect(SponsorCategory.allCases.count == 8)
}
