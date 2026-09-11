import Testing

@testable import Atlas

private let proxiedBanner =
    "https://proxy.example/abc=w2560-fcrop64=1,00005a57ffffa5a8-k-c0xffffffff-no-nd-rw?host=yt3.googleusercontent.com"
private let proxiedAvatar =
    "https://proxy.example/def=s160-c-k-c0x00ffffff-no-rw?host=yt3.googleusercontent.com"

@Test func bannerWidthIsBumpedToTheSmallestServedSizeThatCovers() {
    #expect(
        ThumbnailURL.upgraded(proxiedBanner, pixelWidth: 1170)
            == "https://proxy.example/abc=w1707-fcrop64=1,00005a57ffffa5a8-k-c0xffffffff-no-nd-rw?host=yt3.googleusercontent.com"
    )
    #expect(ThumbnailURL.upgraded(proxiedBanner, pixelWidth: 1060)?.contains("=w1060-fcrop64=") == true)
    #expect(ThumbnailURL.upgraded(proxiedBanner, pixelWidth: 4000)?.contains("=w2560-fcrop64=") == true)
}

@Test func avatarSizeFollowsTheDisplayedPixelSize() {
    #expect(ThumbnailURL.upgraded(proxiedAvatar, pixelWidth: 192)?.contains("=s240-c-k") == true)
    #expect(ThumbnailURL.upgraded(proxiedAvatar, pixelWidth: 88)?.contains("=s88-c-k") == true)
}

@Test func nonGoogleURLsStillTakeTheMaxresPath() {
    let hq = "https://proxy.example/vi/abc/hqdefault.jpg?host=i.ytimg.com"
    #expect(ThumbnailURL.upgraded(hq, pixelWidth: 500) == ThumbnailURL.upgraded(hq))
    #expect(ThumbnailURL.upgraded(hq)?.contains("maxresdefault.jpg") == true)
    #expect(ThumbnailURL.upgraded(nil, pixelWidth: 500) == nil)
}
