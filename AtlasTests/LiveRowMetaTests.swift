import Foundation
import Testing

@testable import Atlas

struct LiveRowMetaTests {
    @Test func watchingUsesCompactCount() {
        #expect(Format.watching(9675) == "9.7K watching")
        #expect(Format.watching(12) == "12 watching")
        #expect(Format.watching(0) == nil)
        #expect(Format.watching(nil) == nil)
    }

    @Test func liveMetaLineJoinsViewersAndStart() {
        let twoHoursAgo = Int64((Date().timeIntervalSince1970 - 2 * 3600) * 1000)
        #expect(
            Format.liveMetaLine(watching: 9675, startedMillis: twoHoursAgo)
                == "9.7K watching · Started 2 hours ago")
    }

    @Test func liveMetaLineDropsUnknownHalves() {
        #expect(Format.liveMetaLine(watching: 1125, startedMillis: nil) == "1.1K watching")
        #expect(Format.liveMetaLine(watching: 1125, startedMillis: -1) == "1.1K watching")
        let justNow = Int64(Date().timeIntervalSince1970 * 1000) - 5_000
        #expect(Format.liveMetaLine(watching: nil, startedMillis: justNow) == "Started just now")
        #expect(Format.liveMetaLine(watching: nil, startedMillis: nil) == "")
    }
}
