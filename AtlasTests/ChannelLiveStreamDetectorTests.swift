import Foundation
import PipedKit
import Testing

@testable import Atlas

@Test func liveStreamCandidatesIncludeExplicitAndAmbiguousLiveRows() throws {
    let explicit = try streamItem(
        id: "explicit01A", duration: -1, livestream: true)
    let ambiguous = try streamItem(
        id: "ambiguous01", duration: 0, livestream: false)
    let upload = try streamItem(
        id: "regular0001", duration: 600, livestream: false)

    let candidates = ChannelLiveStreamDetector.candidates(
        from: [explicit, ambiguous, upload])

    #expect(candidates.map(\.id) == [explicit.id, ambiguous.id])
}

@Test func ambiguousLiveRowsRequireActiveStreamDetails() throws {
    let item = try streamItem(
        id: "ambiguous01", duration: -1, livestream: false)
    let active = try videoDetail(
        livestream: true, duration: -1, hls: "https://example.com/live.m3u8")
    let archived = try videoDetail(
        livestream: true, duration: 3_600, hls: nil)

    #expect(ChannelLiveStreamDetector.isActive(item, detail: active))
    #expect(!ChannelLiveStreamDetector.isActive(item, detail: archived))
}

private func streamItem(
    id: String,
    duration: Int,
    livestream: Bool
) throws -> StreamItem {
    let json = """
        {
          "url": "/watch?v=\(id)",
          "type": "stream",
          "title": "Video \(id)",
          "duration": \(duration),
          "livestream": \(livestream)
        }
        """.data(using: .utf8)!
    return try JSONDecoder().decode(StreamItem.self, from: json)
}

private func videoDetail(
    livestream: Bool,
    duration: Int,
    hls: String?
) throws -> VideoDetail {
    let hlsJSON = hls.map { "\"\($0)\"" } ?? "null"
    let json = """
        {
          "livestream": \(livestream),
          "duration": \(duration),
          "hls": \(hlsJSON)
        }
        """.data(using: .utf8)!
    return try JSONDecoder().decode(VideoDetail.self, from: json)
}
