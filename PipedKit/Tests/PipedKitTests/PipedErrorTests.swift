import Foundation
import Testing

@testable import PipedKit

@Test func surfacesScheduledLiveStreamErrors() {
    let data = """
        {"error":"org.schabi.newpipe.extractor.exceptions.ContentNotAvailableException: Got error LIVE_STREAM_OFFLINE: \\"This live event will begin in 34 hours.\\""}
        """.data(using: .utf8)!

    let error = PipedError.fromHTTPStatus(500, data: data)
    #expect(error.errorDescription == "This live event has not started yet. This live event will begin in 34 hours.")
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
