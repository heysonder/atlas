import SwiftUI

/// Settings → Diagnostics: the MetricKit reports Atlas has archived on this
/// device, with a share button. Reports are aggregated daily by iOS, contain
/// no identifiers, and never leave the device unless shared from here.
struct DiagnosticsSettingsView: View {
    @State private var entries: [DiagnosticsReportStore.Entry] = []
    @State private var exportURL: URL?
    @State private var confirmingDelete = false

    private var metricCount: Int { entries.filter { $0.kind == .metric }.count }
    private var diagnosticCount: Int { entries.filter { $0.kind == .diagnostic }.count }

    var body: some View {
        Form {
            Section {
                LabeledContent("Daily Reports", value: "\(metricCount)")
                LabeledContent("Crash & Hang Reports", value: "\(diagnosticCount)")
                if let latest = entries.first {
                    LabeledContent("Latest", value: latest.date.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                Text("On This Device")
            } footer: {
                Text(footer)
            }

            if !entries.isEmpty {
                Section {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            Task { exportURL = try? await DiagnosticsReportStore.shared.exportArchive() }
                        } label: {
                            Label("Prepare Export", systemImage: "doc.text")
                        }
                    }
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete All Reports", systemImage: "trash")
                    }
                }

                Section("Reports") {
                    ForEach(entries) { entry in
                        HStack {
                            Label(
                                entry.kind == .metric ? "Daily metrics" : "Diagnostic",
                                systemImage: entry.kind == .metric ? "chart.bar" : "exclamationmark.triangle")
                            Spacer()
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .confirmationDialog(
            "Delete all diagnostics reports?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await DiagnosticsReportStore.shared.deleteAll()
                    exportURL = nil
                    await reload()
                }
            }
        }
    }

    private var footer: String {
        guard AppDiagnostics.isSupported else {
            return "Performance reports need iOS 27 or later."
        }
        if entries.isEmpty {
            return
                "iOS delivers an aggregated performance report about once a day, plus a report for any crash or hang. "
                + "Reports include hang and hitch time split by playback path, feed mode, and live chat, contain no personal data, and stay on this device unless you share them."
        }
        return
            "Aggregated by iOS about once a day. Reports contain no personal data and stay on this device unless you share them."
    }

    private func reload() async {
        entries = await DiagnosticsReportStore.shared.entries()
    }
}
