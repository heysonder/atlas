import Testing

@testable import Atlas

@MainActor
@Test func stalledPlaybackRequiresFiniteMeaningfulAdvancement() {
    #expect(PlayerRuntimeFallbackPolicy.hasAdvanced(from: 10, to: 10.76))
    #expect(!PlayerRuntimeFallbackPolicy.hasAdvanced(from: 10, to: 10.75))
    #expect(!PlayerRuntimeFallbackPolicy.hasAdvanced(from: .nan, to: 20))
    #expect(!PlayerRuntimeFallbackPolicy.hasAdvanced(from: 10, to: .infinity))
}
