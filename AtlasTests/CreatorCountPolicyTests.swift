import Testing

@testable import Atlas

@MainActor
@Test func collaboratorCountsUseCheckedClampedArithmetic() {
    #expect(CreatorCountPolicy.additional(Int.max) == CreatorCountPolicy.maximumAdditionalCount)
    #expect(CreatorCountPolicy.expectedTotal(Int.max) == CreatorCountPolicy.maximumAdditionalCount + 1)
    #expect(CreatorCountPolicy.total(primaryCount: Int.max, additionalCount: Int.max) == Int.max)
}
