import Foundation
import Testing

@testable import Atlas

@MainActor
@Test func playbackDiagnosticsTreatsFormatTokensAndControlsAsUntrustedData() {
    let hostile = ["%@%n", "line\nbreak", "tab\tvalue", "control\u{0000}value"]
    for value in hostile {
        #expect(PlaybackDiagnostics.safeToken(value) == "redacted")
    }
    #expect(PlaybackDiagnostics.safeToken("direct-av1-hls") == "direct-av1-hls")
}

@MainActor
@Test func playbackDiagnosticsNeverPreservesURLsOrFilePaths() {
    let sensitive = [
        "https://user:pass@example.com/path?token=secret#fragment",
        "file:///private/var/mobile/secret.mp4",
        "/private/var/mobile/secret.mp4",
        "..\\outside.mp4",
    ]
    for value in sensitive {
        #expect(PlaybackDiagnostics.safeToken(value) == "redacted")
    }
}

@MainActor
@Test func playbackDiagnosticsKeepsOnlySanitizedErrorDomainAndNumericCode() throws {
    let error = NSError(
        domain: "https://example.com/path?secret=token",
        code: 403,
        userInfo: [NSLocalizedDescriptionKey: "file:///private/secret %@%n"])

    let record = try #require(PlaybackDiagnostics.errorCode(error))

    #expect(record == PlaybackDiagnostics.ErrorCode(domain: "redacted", code: 403))
}
