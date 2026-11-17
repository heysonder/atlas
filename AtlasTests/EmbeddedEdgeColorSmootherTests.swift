import Testing

@testable import Atlas

struct EmbeddedEdgeColorSmootherTests {
    @Test func ignoresBriefObjectsAndFlashes() {
        var smoother = EmbeddedEdgeColorSmoother()
        let steady: [UInt8] = [30, 60, 90, 255, 90, 60, 30, 255]
        let expected = steady.map(Double.init)
        let flash: [UInt8] = [255, 255, 255, 255, 0, 0, 0, 255]
        #expect(smoother.update(steady) == expected)
        for _ in 0..<2 { #expect(smoother.update(flash) == expected) }
        for _ in 0..<5 { #expect(smoother.update(steady) == expected) }
    }

    @Test func sustainedSceneChangesEaseInWithoutOvershoot() {
        var smoother = EmbeddedEdgeColorSmoother()
        _ = smoother.update([0, 0, 0, 255])
        var previous = 0.0
        for tick in 0..<60 {
            let result = smoother.update([200, 100, 50, 255])
            #expect(result[0] >= previous)
            #expect(result[0] - previous <= 16)
            #expect(result[0] <= 200)
            #expect(result[3] == 255)
            if tick < 2 { #expect(result[0] == 0) }
            previous = result[0]
        }
        #expect(previous >= 198)
    }
}
