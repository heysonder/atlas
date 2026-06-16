import Testing
import Foundation
@testable import PipedKit

@Test func extractsVideoID() {
    #expect(PipedID.video(fromWatchURL: "/watch?v=s8BB8q2MyXc") == "s8BB8q2MyXc")
    #expect(PipedID.video(fromWatchURL: "/watch?v=abc&t=10s") == "abc")
    #expect(PipedID.video(fromWatchURL: "/channel/UC123") == nil)
}

@Test func extractsChannelID() {
    #expect(PipedID.channel(fromURL: "/channel/UCwrVwiJllwhJUKXKmjLcckQ") == "UCwrVwiJllwhJUKXKmjLcckQ")
    #expect(PipedID.channel(fromURL: nil) == nil)
}

@Test func stripsHTMLDescription() {
    let html = "Get up to 40% off at <a href=\"https://ridge.com/MKBHD\">https://ridge.com/MKBHD</a> "
        + "for Father&#39;s Day!<br><br>MKBHD Merch &amp; more"
    let plain = HTMLText.plain(html)
    #expect(!plain.contains("<a"))
    #expect(!plain.contains("href"))
    #expect(!plain.lowercased().contains("<br>"))
    #expect(plain.contains("https://ridge.com/MKBHD"))
    #expect(plain.contains("Father's Day"))
    #expect(plain.contains("Merch & more"))
    #expect(plain.contains("\n"))
}

@Test func leavesMalformedEntitiesButContinuesDecodingValidEntities() {
    let plain = HTMLText.plain("Bad scalar &#99999999; then &#65; and &#x42; &madeup;")
    #expect(plain.contains("&#99999999;"))
    #expect(plain.contains("A and B"))
    #expect(plain.contains("&madeup;"))
}

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

@Test func prefersHLSWhenPresent() {
    let detail = VideoDetail(
        title: "x", description: nil, uploader: nil, uploaderUrl: nil,
        uploaderAvatar: nil, thumbnailUrl: nil,
        hls: "https://example.com/master.m3u8",
        duration: 1, views: nil, likes: nil, uploaded: nil,
        uploaderVerified: nil, uploaderSubscriberCount: nil, creators: nil, livestream: nil,
        chapters: nil,
        videoStreams: [Stream(url: "https://example.com/360.mp4", format: "MP4",
                              quality: "360p", mimeType: "video/mp4", codec: nil,
                              videoOnly: false, bitrate: nil, width: nil, height: 360, fps: nil)],
        audioStreams: nil, subtitles: nil, relatedStreams: nil, category: nil, tags: nil)
    #expect(detail.playableURL?.absoluteString == "https://example.com/master.m3u8")
}

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

@Test func decodesVideoChapters() throws {
    let json = """
    {
      "title": "WWDC 2026: Is Siri Actually Good Now?",
      "duration": 6684,
      "chapters": [
        {"title": "Intro", "image": "https://pipedproxy.cmf.sh/intro.jpg", "start": 0},
        {"title": "Did they even test this?", "image": "https://pipedproxy.cmf.sh/test.jpg", "start": 74},
        {"title": "Vibe of WWDC", "start": 220}
      ]
    }
    """.data(using: .utf8)!
    let detail = try JSONDecoder().decode(VideoDetail.self, from: json)
    let chapters = try #require(detail.chapters)
    #expect(chapters.count == 3)
    #expect(chapters[0].title == "Intro")
    #expect(chapters[0].image == "https://pipedproxy.cmf.sh/intro.jpg")
    #expect(chapters[0].start == 0)
    #expect(chapters[1].start == 74)
    #expect(chapters[2].title == "Vibe of WWDC")
}

@Test func decodesVideoChaptersLossily() throws {
    let json = """
    {
      "title": "Chapter test",
      "chapters": [
        {"title": "Intro", "start": 0},
        {"title": "Bad", "start": "not-a-number"},
        "bad element",
        {"title": "Main", "start": 42}
      ]
    }
    """.data(using: .utf8)!
    let detail = try JSONDecoder().decode(VideoDetail.self, from: json)
    let chapters = try #require(detail.chapters)
    #expect(chapters.map(\.title) == ["Intro", "Main"])
    #expect(chapters.map(\.start) == [0, 42])
}

@Test func decodesNullVideoChaptersAsMissing() throws {
    let json = #"{"title":"Chapter test","chapters":null}"#.data(using: .utf8)!
    let detail = try JSONDecoder().decode(VideoDetail.self, from: json)
    #expect(detail.chapters == nil)
}

@Test func extractsCommentTimestamps() throws {
    let json = """
    {"commentText":"Intro <a>1:23</a><br>Deep dive 1:02:03 and long one 123:45"}
    """.data(using: .utf8)!
    let comment = try JSONDecoder().decode(PipedKit.Comment.self, from: json)
    #expect(comment.timestamps.map { $0.seconds } == [83, 3723, 7425])
    #expect(comment.timestamps.map { $0.label } == ["1:23", "1:02:03", "123:45"])
}

@Test func extractsDescriptionChapterTimestamps() {
    let description = """
    Chapters
    00:00 Intro
    02:15 Setup
    1:03:45 Full walkthrough
    """
    let timestamps = CommentTimestamp.extract(from: description)
    #expect(timestamps.map(\.seconds) == [0, 135, 3825])
    #expect(timestamps.map(\.label) == ["00:00", "02:15", "1:03:45"])
}

@Test func ignoresInvalidCommentTimestamps() throws {
    let json = """
    {"commentText":"Ratios like 16:9, invalid seconds 1:75, and chained 1:02:03:04 are not timestamps."}
    """.data(using: .utf8)!
    let comment = try JSONDecoder().decode(PipedKit.Comment.self, from: json)
    #expect(comment.timestamps.isEmpty)
}

@Test func sponsorCategoryRawValues() {
    #expect(SponsorCategory.musicOfftopic.rawValue == "music_offtopic")
    #expect(SponsorCategory(rawValue: "interaction") == .interaction)
    #expect(SponsorCategory(rawValue: "nonsense") == nil)
    #expect(SponsorCategory.allCases.count == 8)
}

@Test func fallsBackToHighestProgressive() {
    let detail = VideoDetail(
        title: "x", description: nil, uploader: nil, uploaderUrl: nil,
        uploaderAvatar: nil, thumbnailUrl: nil, hls: "",
        duration: 1, views: nil, likes: nil, uploaded: nil,
        uploaderVerified: nil, uploaderSubscriberCount: nil, creators: nil, livestream: nil,
        chapters: nil,
        videoStreams: [
            Stream(url: "https://example.com/360.mp4", format: "MP4", quality: "360p",
                   mimeType: "video/mp4", codec: nil, videoOnly: false, bitrate: nil,
                   width: nil, height: 360, fps: nil),
            Stream(url: "https://example.com/720.mp4", format: "MP4", quality: "720p",
                   mimeType: "video/mp4", codec: nil, videoOnly: false, bitrate: nil,
                   width: nil, height: 720, fps: nil),
            Stream(url: "https://example.com/1080.mp4", format: "MP4", quality: "1080p",
                   mimeType: "video/mp4", codec: nil, videoOnly: true, bitrate: nil,
                   width: nil, height: 1080, fps: nil) // video-only, must be ignored
        ],
        audioStreams: nil, subtitles: nil, relatedStreams: nil, category: nil, tags: nil)
    #expect(detail.playableURL?.absoluteString == "https://example.com/720.mp4")
}

@Test func decodesAndPrefersSubtitles() throws {
    let json = """
    {
      "subtitles": [
        {"autoGenerated": true, "code": "en", "mimeType": "application/ttml+xml", "name": "English auto", "url": "https://example.com/auto.ttml"},
        {"autoGenerated": false, "code": "en-US", "mimeType": "application/ttml+xml", "name": "English", "url": "https://example.com/manual.ttml"}
      ]
    }
    """.data(using: .utf8)!
    let detail = try JSONDecoder().decode(VideoDetail.self, from: json)
    let preferred = try #require(detail.preferredSubtitle(preferredLanguages: ["en-US"]))
    #expect(preferred.url == "https://example.com/manual.ttml")
}

@Test func decodesAudioLanguageMetadata() throws {
    let json = """
    {
      "url": "https://example.com/en.m4a",
      "mimeType": "audio/mp4",
      "bitrate": 128000,
      "audioTrackId": "en.0",
      "audioTrackName": "English original",
      "audioTrackType": "original",
      "audioTrackLocale": "en-US",
      "language": "English",
      "languageCode": "en",
      "name": "English"
    }
    """.data(using: .utf8)!

    let stream = try JSONDecoder().decode(Stream.self, from: json)
    #expect(stream.audioTrackName == "English original")
    #expect(stream.audioTrackType == "original")
    #expect(stream.audioTrackLocale == "en-US")
    #expect(stream.languageCode == "en")
    #expect(stream.audioLanguageHints.contains("English original"))
    #expect(stream.audioLanguageHints.contains("en-US"))
}

@Test func prefersAudioLanguageOverBitrateForComposedSource() throws {
    let detail = VideoDetail(
        title: "x", description: nil, uploader: nil, uploaderUrl: nil,
        uploaderAvatar: nil, thumbnailUrl: nil, hls: nil,
        duration: 1, views: nil, likes: nil, uploaded: nil,
        uploaderVerified: nil, uploaderSubscriberCount: nil, creators: nil, livestream: nil,
        chapters: nil,
        videoStreams: [
            Stream(url: "https://example.com/1080.mp4", format: "MP4", quality: "1080p",
                   mimeType: "video/mp4", codec: "avc1.640028", videoOnly: true,
                   bitrate: nil, width: 1920, height: 1080, fps: 30)
        ],
        audioStreams: [
            Stream(url: "https://example.com/es-dubbed.m4a", format: "M4A", quality: nil,
                   mimeType: "audio/mp4", codec: nil, videoOnly: nil, bitrate: 256000,
                   width: nil, height: nil, fps: nil,
                   audioTrackName: "Spanish dubbed", audioTrackType: "dubbed", languageCode: "es"),
            Stream(url: "https://example.com/en-original.m4a", format: "M4A", quality: nil,
                   mimeType: "audio/mp4", codec: nil, videoOnly: nil, bitrate: 128000,
                   width: nil, height: nil, fps: nil,
                   audioTrackName: "English original", audioTrackType: "original", languageCode: "en")
        ],
        subtitles: nil, relatedStreams: nil, category: nil, tags: nil)

    let source = try #require(detail.bestComposedSource(allowAV1: false, preferredLanguages: ["en-US"]))
    #expect(source.audio.absoluteString == "https://example.com/en-original.m4a")
    #expect(VideoDetail.audioScore(detail.audioStreams![1], preferredLanguages: ["en-US"])
            > VideoDetail.audioScore(detail.audioStreams![0], preferredLanguages: ["en-US"]))
}

@Test func surfacesScheduledLiveStreamErrors() {
    let data = """
    {"error":"org.schabi.newpipe.extractor.exceptions.ContentNotAvailableException: Got error LIVE_STREAM_OFFLINE: \\"This live event will begin in 34 hours.\\""}
    """.data(using: .utf8)!

    let error = PipedError.fromHTTPStatus(500, data: data)
    #expect(error.errorDescription == "This live event has not started yet. This live event will begin in 34 hours.")
}

@Test func decodesVideoCreators() throws {
    let json = """
    {
      "uploader": "Main Channel",
      "uploaderUrl": "/channel/UCmain",
      "creators": [
        {"name": "Main Channel", "url": "/channel/UCmain", "avatar": "https://example.com/main.jpg", "role": "owner"},
        {"name": "Other Creator", "url": "/channel/UCother", "avatar": "https://example.com/other.jpg", "role": "collaborator"}
      ]
    }
    """.data(using: .utf8)!
    let detail = try JSONDecoder().decode(VideoDetail.self, from: json)
    let creators = try #require(detail.creators)
    #expect(creators.count == 2)
    #expect(creators[0].name == "Main Channel")
    #expect(creators[0].channelID == "UCmain")
    #expect(creators[1].avatar == "https://example.com/other.jpg")
    #expect(creators[1].role == "collaborator")
}
