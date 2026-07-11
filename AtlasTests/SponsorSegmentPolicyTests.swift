import PipedKit
import Testing

@testable import Atlas

@MainActor
@Test func sponsorSegmentsAreShapeCheckedAndCappedBeforeSorting() {
    let malformed = SponsorSegment(segment: [1], category: "sponsor")
    let nonfinite = SponsorSegment(segment: [.nan, 2], category: "sponsor")
    let reversed = SponsorSegment(segment: [10, 5], category: "sponsor")
    let valid = (0..<300).map {
        SponsorSegment(segment: [Double($0), Double($0) + 0.5], category: "sponsor")
    }
    let usable = SponsorSegmentPolicy.usableSegments(
        [malformed, nonfinite, reversed] + valid.reversed())

    #expect(usable.count == 200)
    #expect(usable.first?.start == 100)
    #expect(usable.last?.start == 299)
    #expect(usable.allSatisfy { $0.segment.count == 2 && $0.end > $0.start })
}
