import Testing
import Foundation
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

@Test func buildsAV1HLSMasterURLFromInstanceBase() {
    let client = PipedClient(baseURL: URL(string: "https://piped.example")!)

    #expect(
        client.av1HLSMasterURL(videoID: "WOzcFkld6_g").absoluteString
            == "https://piped.example/hls/av1/WOzcFkld6_g/master.m3u8")
}

@Test func detectsAV1VideoStreamAvailability() {
    func detail(_ streams: [PipedKit.Stream]?) -> VideoDetail {
        VideoDetail(
            title: "x", description: nil, uploader: nil, uploaderUrl: nil,
            uploaderAvatar: nil, thumbnailUrl: nil, hls: "https://example.com/hls.m3u8",
            duration: 1, views: nil, likes: nil, uploaded: nil,
            uploaderVerified: nil, uploaderSubscriberCount: nil, creators: nil, livestream: nil,
            chapters: nil, videoStreams: streams,
            audioStreams: nil, subtitles: nil, relatedStreams: nil, category: nil, tags: nil)
    }
    func stream(_ codec: String) -> PipedKit.Stream {
        PipedKit.Stream(url: "https://example.com/v.mp4", format: "MP4", quality: "1080p",
               mimeType: "video/mp4", codec: codec, videoOnly: true, bitrate: nil,
               width: 1920, height: 1080, fps: 30)
    }

    // HLS-only extraction (the common case): no AV1 HLS attempt should be made.
    #expect(detail([]).hasAV1VideoStream == false)
    #expect(detail(nil).hasAV1VideoStream == false)
    // Only H.264 adaptive streams — still no AV1 master to build.
    #expect(detail([stream("avc1.640028")]).hasAV1VideoStream == false)
    // At least one AV1 stream — the AV1 HLS endpoint can serve a master.
    #expect(detail([stream("avc1.640028"), stream("av01.0.12M.08")]).hasAV1VideoStream)
}

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
    #expect(page.nextpage == "shorts-token")
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

// MARK: - Lossy page decoding

@Test func decodesVideoDetailStreamsAndRelatedLossily() throws {
    let json = """
    {
      "title": "Lossy test",
      "videoStreams": [
        {"url": "https://example.com/1080.mp4", "mimeType": "video/mp4", "codec": "avc1.640028", "videoOnly": true, "height": 1080},
        {"url": 12345},
        {"url": "https://example.com/720.mp4", "mimeType": "video/mp4", "codec": "avc1.640028", "videoOnly": true, "height": 720}
      ],
      "audioStreams": [
        {"url": "https://example.com/a.m4a", "mimeType": "audio/mp4", "bitrate": 128000},
        "junk"
      ],
      "subtitles": [
        {"code": "en", "name": "English", "url": "https://example.com/en.ttml"},
        {"autoGenerated": "not-a-bool"}
      ],
      "relatedStreams": [
        {"url": "/watch?v=good1", "type": "stream", "title": "Good"},
        {"url": 42},
        {"url": "/watch?v=good2", "type": "stream", "title": "Also good"}
      ]
    }
    """.data(using: .utf8)!

    let detail = try JSONDecoder().decode(VideoDetail.self, from: json)
    #expect(detail.videoStreams?.compactMap(\.height) == [1080, 720])
    #expect(detail.audioStreams?.count == 1)
    #expect(detail.subtitles?.compactMap(\.code) == ["en"])
    #expect(detail.relatedStreams?.compactMap(\.videoID) == ["good1", "good2"])
}

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
    #expect(response.nextpage == "token")
    #expect(response.corrected == false)
}

@Test func decodesCommentsLossily() throws {
    let json = """
    {
      "comments": [
        {"author": "a", "commentId": "c1", "commentText": "first", "likeCount": 3},
        {"likeCount": "many"},
        {"author": "b", "commentId": "c2", "commentText": "second"}
      ],
      "nextpage": "token",
      "disabled": false,
      "commentCount": 2
    }
    """.data(using: .utf8)!

    let page = try JSONDecoder().decode(CommentsPage.self, from: json)
    #expect(page.comments?.compactMap(\.commentId) == ["c1", "c2"])
    #expect(page.nextpage == "token")
    #expect(page.disabled == false)
    #expect(page.commentCount == 2)
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
    #expect(page.nextpage == "shorts-token")
}

// MARK: - HTML entity decoding order

@Test func decodesDoubleEncodedEntitiesExactlyOneLevel() {
    #expect(HTMLText.plain("&amp;#39;") == "&#39;")
    #expect(HTMLText.plain("&amp;lt;") == "&lt;")
    #expect(HTMLText.plain("&amp;") == "&")
    #expect(HTMLText.plain("&amp;amp;") == "&amp;")
}

@Test func decodesSingleEncodedEntities() {
    #expect(HTMLText.plain("a &lt;b&gt; &quot;c&quot; &apos;d&apos; &#39;e&#x27;") == "a <b> \"c\" 'd' 'e'")
    #expect(HTMLText.plain("Tom &amp; Jerry") == "Tom & Jerry")
}

// MARK: - Server error mapping

@Test func surfacesBotDetectionErrors() {
    let data = """
    {"error":"org.schabi.newpipe.extractor.exceptions.ExtractionException: SignInConfirmNotBotException"}
    """.data(using: .utf8)!
    let error = PipedError.fromHTTPStatus(500, data: data)
    #expect(error.errorDescription == "This instance was blocked by YouTube. Try another instance.")
}

@Test func fallsBackToHTTPStatusForNonJSONErrorBodies() {
    let error = PipedError.fromHTTPStatus(502, data: Data("Bad Gateway".utf8))
    guard case .http(let code) = error else {
        Issue.record("expected .http, got \(error)")
        return
    }
    #expect(code == 502)
    #expect(error.errorDescription == "Server returned HTTP 502.")

    let emptyMessage = PipedError.fromHTTPStatus(500, data: Data(#"{"error":"  "}"#.utf8))
    guard case .http(500) = emptyMessage else {
        Issue.record("expected .http(500), got \(emptyMessage)")
        return
    }
}

@Test func surfacesGenericUpstreamErrorMessages() {
    let data = """
    {"error":"This video is age restricted and unavailable without signing in."}
    """.data(using: .utf8)!
    let error = PipedError.fromHTTPStatus(403, data: data)
    guard case .upstream(let message) = error else {
        Issue.record("expected .upstream, got \(error)")
        return
    }
    #expect(message == "This video is age restricted and unavailable without signing in.")
    #expect(error.errorDescription == message)
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

// MARK: - Stream selection helpers

private func makeDetail(
    hls: String? = nil,
    videoStreams: [PipedKit.Stream]? = nil,
    audioStreams: [PipedKit.Stream]? = nil,
    subtitles: [Subtitle]? = nil
) -> VideoDetail {
    VideoDetail(
        title: "x", description: nil, uploader: nil, uploaderUrl: nil,
        uploaderAvatar: nil, thumbnailUrl: nil, hls: hls,
        duration: 1, views: nil, likes: nil, uploaded: nil,
        uploaderVerified: nil, uploaderSubscriberCount: nil, creators: nil, livestream: nil,
        chapters: nil, videoStreams: videoStreams, audioStreams: audioStreams,
        subtitles: subtitles, relatedStreams: nil, category: nil, tags: nil)
}

private func makeVideoStream(
    url: String, mime: String = "video/mp4", codec: String? = "avc1.640028",
    videoOnly: Bool = true, height: Int? = nil
) -> PipedKit.Stream {
    PipedKit.Stream(url: url, format: nil, quality: nil, mimeType: mime, codec: codec,
                    videoOnly: videoOnly, bitrate: nil, width: nil, height: height, fps: nil)
}

@Test func codecLessH264FallbackRequiresVideoMime() {
    let progressiveVideo = makeVideoStream(url: "https://example.com/v.mp4", codec: "", videoOnly: false)
    #expect(progressiveVideo.isH264)

    let audio = makeVideoStream(url: "https://example.com/a.m4a", mime: "audio/mp4", codec: "", videoOnly: false)
    #expect(!audio.isH264)
    #expect(audio.isPlayableAudio)

    let av1 = makeVideoStream(url: "https://example.com/v.mp4", codec: "av01.0.12M.08")
    #expect(!av1.isH264)
    #expect(makeVideoStream(url: "https://example.com/v.mp4").isH264)
}

@Test func bestProgressiveDownloadSkipsVP9AndWebM() throws {
    let detail = makeDetail(videoStreams: [
        makeVideoStream(url: "https://example.com/1080.webm", mime: "video/webm", codec: "vp9", videoOnly: false, height: 1080),
        makeVideoStream(url: "https://example.com/720.mp4", videoOnly: false, height: 720),
        makeVideoStream(url: "https://example.com/2160.mp4", videoOnly: true, height: 2160)
    ])
    let download = try #require(detail.bestProgressiveDownload)
    #expect(download.url.absoluteString == "https://example.com/720.mp4")
    #expect(download.height == 720)

    let vp9Only = makeDetail(videoStreams: [
        makeVideoStream(url: "https://example.com/1080.webm", mime: "video/webm", codec: "vp9", videoOnly: false, height: 1080)
    ])
    #expect(vp9Only.bestProgressiveDownload == nil)
}

@Test func bestComposedSourceUsesAV1OnlyWhenAllowed() throws {
    let audio = PipedKit.Stream(
        url: "https://example.com/a.m4a", format: nil, quality: nil, mimeType: "audio/mp4",
        codec: nil, videoOnly: nil, bitrate: 128_000, width: nil, height: nil, fps: nil)
    let detail = makeDetail(
        videoStreams: [
            makeVideoStream(url: "https://example.com/1080-h264.mp4", height: 1080),
            makeVideoStream(url: "https://example.com/2160-av1.mp4", codec: "av01.0.12M.08", height: 2160)
        ],
        audioStreams: [audio])

    let withAV1 = try #require(detail.bestComposedSource(allowAV1: true, preferredLanguages: ["en"]))
    #expect(withAV1.video.absoluteString == "https://example.com/2160-av1.mp4")
    #expect(withAV1.height == 2160)

    let withoutAV1 = try #require(detail.bestComposedSource(allowAV1: false, preferredLanguages: ["en"]))
    #expect(withoutAV1.video.absoluteString == "https://example.com/1080-h264.mp4")
    #expect(withoutAV1.height == 1080)
}

@Test func bestComposedSourceReturnsNilWithoutPlayableAudio() {
    let opus = PipedKit.Stream(
        url: "https://example.com/a.webm", format: nil, quality: nil, mimeType: "audio/webm",
        codec: "opus", videoOnly: nil, bitrate: 160_000, width: nil, height: nil, fps: nil)
    let detail = makeDetail(
        videoStreams: [makeVideoStream(url: "https://example.com/1080.mp4", height: 1080)],
        audioStreams: [opus])
    #expect(detail.bestComposedSource(allowAV1: true, preferredLanguages: ["en"]) == nil)
}

@Test func reportsMaxAV1AndNonAV1StreamHeights() {
    let detail = makeDetail(videoStreams: [
        makeVideoStream(url: "https://example.com/1440-av1.mp4", codec: "av01.0.12M.08", height: 1440),
        makeVideoStream(url: "https://example.com/2160-av1.mp4", codec: "av01.0.12M.08", height: 2160),
        makeVideoStream(url: "https://example.com/1080-h264.mp4", height: 1080),
        makeVideoStream(url: "https://example.com/720-h264.mp4", height: 720)
    ])
    #expect(detail.maxAV1VideoStreamHeight == 2160)
    #expect(detail.maxNonAV1VideoStreamHeight == 1080)

    #expect(makeDetail(videoStreams: []).maxAV1VideoStreamHeight == nil)
    #expect(makeDetail(videoStreams: nil).maxNonAV1VideoStreamHeight == nil)
}

// MARK: - Subtitle preference

@Test func subtitleNameMatchingUsesWordBoundaries() throws {
    let detail = makeDetail(subtitles: [
        Subtitle(autoGenerated: false, code: "", mimeType: nil,
                 name: "English (United States)", url: "https://example.com/en.ttml"),
        Subtitle(autoGenerated: false, code: "fr", mimeType: nil,
                 name: "French", url: "https://example.com/fr.ttml"),
        Subtitle(autoGenerated: false, code: "es", mimeType: nil,
                 name: "Spanish", url: "https://example.com/es.ttml")
    ])
    // "French" contains the substring "en"; a word-boundary match must not rank it
    // above (or tied with) the actual English track for an English-preferring user.
    let preferred = try #require(detail.preferredSubtitle(preferredLanguages: ["en"]))
    #expect(preferred.name == "English (United States)")
}

@Test func preferredSubtitleFallsBackToBaseEnglishCode() throws {
    let detail = makeDetail(subtitles: [
        Subtitle(autoGenerated: false, code: "fr", mimeType: nil,
                 name: "French", url: "https://example.com/fr.ttml"),
        Subtitle(autoGenerated: false, code: "en", mimeType: nil,
                 name: "English", url: "https://example.com/en.ttml")
    ])
    let preferred = try #require(detail.preferredSubtitle(preferredLanguages: ["en-GB"]))
    #expect(preferred.code == "en")
}
