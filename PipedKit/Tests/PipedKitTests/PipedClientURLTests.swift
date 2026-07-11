import Foundation
import Testing

@testable import PipedKit

@Test func encodesPipedQueryValuesThatServersMayDecodeAsFormSyntax() throws {
    let url = try PipedClient.url(
        baseURL: URL(string: "https://piped.example")!,
        path: "search",
        query: ["q": "jazz + funk C++ a&b=c?d#e[f]", "filter": "videos"])

    let absolute = url.absoluteString
    #expect(absolute.contains("q=jazz%20%2B%20funk%20C%2B%2B%20a%26b%3Dc%3Fd%23e%5Bf%5D"))
    #expect(!absolute.contains("jazz+%20funk"))
    #expect(!absolute.contains("C++"))
}

@Test func buildsAV1HLSMasterURLFromInstanceBase() {
    let client = PipedClient(baseURL: URL(string: "https://piped.example")!)

    #expect(
        client.av1HLSMasterURL(videoID: "WOzcFkld6_g").absoluteString
            == "https://piped.example/hls/av1/WOzcFkld6_g/master.m3u8")
}

@Test func buildsChannelTabURLWithEncodedDataAndNextPage() throws {
    let data = #"{"originalUrl":"https://www.youtube.com/UCchannel/shorts","contentFilters":["shorts"]}"#
    let url = try PipedClient.url(
        baseURL: URL(string: "https://piped.example")!,
        path: "channels/tabs",
        query: ["data": data, "nextpage": "token+with&syntax"])

    let absolute = url.absoluteString
    #expect(absolute.contains("channels/tabs?"))
    #expect(absolute.contains("data=%7B%22originalUrl%22"))
    #expect(absolute.contains("%5B%22shorts%22%5D"))
    #expect(absolute.contains("nextpage=token%2Bwith%26syntax"))
    #expect(!absolute.contains("token+with&syntax"))
}

// MARK: - Sponsor category JSON

@Test func encodesSponsorCategoriesAsJSON() throws {
    #expect(try PipedClient.sponsorCategoriesJSON(["sponsor", "intro"]) == #"["sponsor","intro"]"#)

    let tricky = try PipedClient.sponsorCategoriesJSON([#"quo"te"#, "back\\slash"])
    let roundTripped = try JSONDecoder().decode([String].self, from: Data(tricky.utf8))
    #expect(roundTripped == [#"quo"te"#, "back\\slash"])
}

// MARK: - Instance string validation

@Test func rejectsInvalidInstanceStrings() {
    #expect(PipedClient(instanceString: "https://api.piped.example") != nil)
    #expect(PipedClient(instanceString: "http://localhost") != nil)
    #expect(PipedClient(instanceString: "abc") == nil)
    #expect(PipedClient(instanceString: "ftp://x") == nil)
    #expect(PipedClient(instanceString: "https://") == nil)
    #expect(PipedClient(instanceString: "") == nil)
}
