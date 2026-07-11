import Foundation
import Testing

@testable import PipedKit

@Test func stripsHTMLDescription() {
    let html =
        "Get up to 40% off at <a href=\"https://ridge.com/MKBHD\">https://ridge.com/MKBHD</a> "
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
