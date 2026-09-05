import Foundation
import os

#if canImport(MetricKit)
    import MetricKit
#endif
#if canImport(StateReporting)
    import StateReporting
#endif

/// On-device performance diagnostics (iOS 27+): subscribes to MetricKit's
/// daily `MetricReport`s and per-event `DiagnosticReport`s, archives them as
/// JSON in `DiagnosticsReportStore`, and tells the system which app state is
/// active (playback path, feed mode, live chat) through StateReporting so
/// hang/hitch time comes back split by those states.
///
/// Nothing here talks to the network. Reports stay on the device until the
/// user shares them from Settings → Diagnostics.
@MainActor
enum AppDiagnostics {
    private nonisolated static let log = Logger(subsystem: "sh.cmf.atlas", category: "diagnostics")

    /// Reverse-DNS state domains. Stable across versions — renaming one starts
    /// a fresh data series.
    enum Domain {
        static let playback = "sh.cmf.atlas.playback"
        static let feed = "sh.cmf.atlas.feed"
        static let liveChat = "sh.cmf.atlas.livechat"
        static let all = [playback, feed, liveChat]
    }

    static var isSupported: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    private static var reportTasks: [Task<Void, Never>] = []
    private static var manager: AnyObject?
    /// Last state per domain, so backgrounding can clear everything and
    /// foregrounding can put it back. Without this a state kept accruing
    /// while the app was suspended (11h of "direct-av1-hls" in one report).
    private static var currentStates: [String: String] = [:]
    private static var isSuspended = false

    /// Call on `scenePhase` changes: states are only "active" while the app is.
    static func sceneDidChange(active: Bool) {
        guard isSuspended == active else { return }
        isSuspended = !active
        for domain in Domain.all {
            transition(domain: domain, to: active ? currentStates[domain] : nil)
        }
    }

    /// Start once at launch. Safe to call again; later calls are no-ops.
    static func start() {
        guard reportTasks.isEmpty else { return }
        #if canImport(MetricKit)
            guard #available(iOS 27, *) else { return }
            let manager = MetricManager(
                enabledStateReportingDomains: Set(Domain.all.map { StateReportingDomain(rawValue: $0) }))
            self.manager = manager
            reportTasks = [
                Task.detached(priority: .utility) {
                    for await report in manager.metricReports {
                        await archive(report, kind: .metric)
                    }
                },
                Task.detached(priority: .utility) {
                    for await report in manager.diagnosticReports {
                        await archive(report, kind: .diagnostic)
                    }
                },
            ]
            log.info("MetricKit reporting started")
        #endif
    }

    private nonisolated static func archive(_ report: some Encodable, kind: DiagnosticsReportStore.Kind) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(report)
            try await DiagnosticsReportStore.shared.save(data, kind: kind)
            log.info("archived \(kind.rawValue, privacy: .public) report (\(data.count, privacy: .public) bytes)")
        } catch {
            log.error("failed to archive \(kind.rawValue, privacy: .public) report")
        }
    }

    // MARK: State reporting

    /// Playback path in use, e.g. "direct-av1-hls", "composed-initial", "local".
    /// Pass nil when playback stops.
    static func reportPlayback(source: String?) {
        report(domain: Domain.playback, state: source.map { PlaybackDiagnostics.safeToken($0) })
    }

    static func reportFeed(mode: FeedMode) {
        report(domain: Domain.feed, state: mode.rawValue)
    }

    /// Live chat pane visible (polling) or not.
    static func reportLiveChat(active: Bool) {
        report(domain: Domain.liveChat, state: active ? "on" : nil)
    }

    private static func report(domain: String, state: String?) {
        if let state { currentStates[domain] = state } else { currentStates[domain] = nil }
        guard !isSuspended else { return }
        transition(domain: domain, to: state)
    }

    private static func transition(domain: String, to state: String?) {
        #if canImport(StateReporting)
            guard #available(iOS 27, *) else { return }
            let reporter: StateReporter<Never, Never> = StateReporter.reporter(for: domain)
            reporter.reportTransition(to: state)
        #endif
    }
}
