import Foundation
import Testing

@testable import Atlas

struct SocialFeaturesGateTests {
    @Test func thirteenAndOverIsAllowed() {
        #expect(SocialFeaturesGate.verdict(lowerBound: 13, upperBound: nil) == .allowed)
        #expect(SocialFeaturesGate.verdict(lowerBound: 18, upperBound: nil) == .allowed)
    }

    @Test func underThirteenIsBlocked() {
        #expect(SocialFeaturesGate.verdict(lowerBound: nil, upperBound: 12) == .underage)
        #expect(SocialFeaturesGate.verdict(lowerBound: 5, upperBound: 12) == .underage)
    }

    @Test func ambiguousRangeDoesNotUnlock() {
        #expect(SocialFeaturesGate.verdict(lowerBound: nil, upperBound: nil) == .underage)
        #expect(SocialFeaturesGate.verdict(lowerBound: 10, upperBound: nil) == .underage)
    }

    @MainActor @Test func cachedVerdictExpiresAfterInterval() {
        let defaults = UserDefaults(suiteName: "gate-tests-\(UUID().uuidString)")!
        let gate = SocialFeaturesGate(defaults: defaults)
        #expect(gate.needsCheck)
        #expect(gate.allowsSocialFeatures == !SocialFeaturesGate.isEnforced)
        gate.apply(.allowed)
        #expect(gate.allowsSocialFeatures)
        #expect(gate.needsCheck == false)
        gate.apply(.allowed, at: Date().addingTimeInterval(-SocialFeaturesGate.recheckInterval - 1))
        #expect(gate.needsCheck)
        // Persisted across instances.
        #expect(SocialFeaturesGate(defaults: defaults).status == .allowed)
    }
}
