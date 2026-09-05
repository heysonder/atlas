import Foundation
import Testing

@testable import Atlas

struct AvatarRetryPolicyTests {
    private final class Clock: @unchecked Sendable {
        nonisolated(unsafe) var now: TimeInterval = 1_000
    }

    private func makePolicy(clock: Clock) -> AvatarRetryPolicy {
        AvatarRetryPolicy(
            configuration: .init(inViewRetries: 2, failureBudget: 3, cooldown: 600),
            now: { clock.now })
    }

    @Test func failureBudgetStopsAttempts() async {
        let clock = Clock()
        let policy = makePolicy(clock: clock)
        let url = "https://example.test/a.jpg"
        for _ in 0..<3 {
            #expect(await policy.shouldAttempt(url))
            await policy.recordFailure(url)
        }
        #expect(await policy.shouldAttempt(url) == false)
        #expect(await policy.failureCount(url) == 3)
    }

    @Test func cooldownAllowsOneFreshAttempt() async {
        let clock = Clock()
        let policy = makePolicy(clock: clock)
        let url = "https://example.test/b.jpg"
        for _ in 0..<3 { await policy.recordFailure(url) }
        #expect(await policy.shouldAttempt(url) == false)
        clock.now += 601
        #expect(await policy.shouldAttempt(url))
        await policy.recordFailure(url)
        #expect(await policy.shouldAttempt(url) == false)
    }

    @Test func successClearsHistory() async {
        let clock = Clock()
        let policy = makePolicy(clock: clock)
        let url = "https://example.test/c.jpg"
        for _ in 0..<3 { await policy.recordFailure(url) }
        await policy.recordSuccess(url)
        #expect(await policy.shouldAttempt(url))
        #expect(await policy.failureCount(url) == 0)
    }

    @Test func inViewRetriesAreBounded() {
        let policy = AvatarRetryPolicy(configuration: .init(inViewRetries: 2))
        #expect(policy.inViewDelay(forRetry: 0) == .seconds(1.5))
        #expect(policy.inViewDelay(forRetry: 1) == .seconds(4))
        #expect(policy.inViewDelay(forRetry: 2) == nil)
    }
}
