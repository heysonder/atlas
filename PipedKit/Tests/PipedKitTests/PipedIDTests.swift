import Foundation
import Testing

@testable import PipedKit

@Test func extractsVideoID() {
    #expect(PipedID.video(fromWatchURL: "/watch?v=s8BB8q2MyXc") == "s8BB8q2MyXc")
    #expect(PipedID.video(fromWatchURL: "/watch?v=abc&t=10s") == "abc")
    #expect(PipedID.video(fromWatchURL: "/channel/UC123") == nil)
}

@Test func extractsVideoIDFromAbsoluteWatchURLs() {
    #expect(PipedID.video(fromWatchURL: "https://youtube.com/watch?v=s8BB8q2MyXc") == "s8BB8q2MyXc")
    #expect(PipedID.video(fromWatchURL: "https://www.youtube.com/watch?v=abc&t=10s") == "abc")
    #expect(PipedID.video(fromWatchURL: "not a url at all %%%") == nil)
    #expect(PipedID.video(fromWatchURL: "") == nil)
    #expect(PipedID.video(fromWatchURL: nil) == nil)
}

@Test func extractsChannelID() {
    #expect(PipedID.channel(fromURL: "/channel/UCwrVwiJllwhJUKXKmjLcckQ") == "UCwrVwiJllwhJUKXKmjLcckQ")
    #expect(PipedID.channel(fromURL: nil) == nil)
}
