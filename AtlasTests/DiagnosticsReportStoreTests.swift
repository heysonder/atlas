import Foundation
import Testing

@testable import Atlas

struct DiagnosticsReportStoreTests {
    private func makeStore(retention: TimeInterval = 3600, maximumCount: Int = 100) -> DiagnosticsReportStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-tests-\(UUID().uuidString)", isDirectory: true)
        return DiagnosticsReportStore(directory: dir, retention: retention, maximumCount: maximumCount)
    }

    @Test func savesAndListsNewestFirst() async throws {
        let store = makeStore()
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try await store.save(Data("{\"a\":1}".utf8), kind: .metric, date: base)
        try await store.save(Data("{\"b\":2}".utf8), kind: .diagnostic, date: base.addingTimeInterval(60))
        let entries = await store.entries()
        #expect(entries.count == 2)
        #expect(entries.first?.kind == .diagnostic)
        #expect(entries.allSatisfy { $0.size > 0 })
    }

    @Test func prunesBeyondMaximumCount() async throws {
        let store = makeStore(maximumCount: 2)
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for i in 0..<4 {
            try await store.save(Data("{}".utf8), kind: .metric, date: base.addingTimeInterval(Double(i) * 60))
        }
        #expect(await store.entries().count == 2)
    }

    @Test func exportBundlesEveryReport() async throws {
        let store = makeStore()
        try await store.save(Data("{\"x\":1}".utf8), kind: .metric)
        try await store.save(Data("{\"y\":2}".utf8), kind: .diagnostic)
        let url = try await store.exportArchive()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
        #expect(json?.count == 2)
        #expect(json?.contains { ($0["kind"] as? String) == "diagnostic" } == true)
    }

    @Test func fileNamesAreKindPrefixed() {
        let name = DiagnosticsReportStore.fileName(kind: .metric, date: Date(timeIntervalSince1970: 0))
        #expect(name.hasPrefix("metric-1970-01-01"))
        #expect(name.hasSuffix(".json"))
    }
}

@MainActor
struct AppDiagnosticsStateTests {
    @Test func sceneChangesAreIdempotent() {
        // Exercises the suspend/resume bookkeeping without StateReporting
        // (no-op on the simulator below iOS 27); must not trap.
        AppDiagnostics.reportFeed(mode: .subscriptions)
        AppDiagnostics.sceneDidChange(active: false)
        AppDiagnostics.sceneDidChange(active: false)
        AppDiagnostics.sceneDidChange(active: true)
        AppDiagnostics.reportPlayback(source: nil)
        AppDiagnostics.sceneDidChange(active: true)
    }
}
