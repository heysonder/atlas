import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

/// Export / import of the user's data (history, subscriptions, playlists,
/// ratings) to and from a JSON file.
struct BackupSettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var exportFile: ExportFile?
    @State private var importing = false
    @State private var backupResult: String?

    var body: some View {
        Form {
            Section {
                Button("Export Data…", systemImage: "square.and.arrow.up") { exportData() }
                Button("Import Data…", systemImage: "square.and.arrow.down") { importing = true }
            } footer: {
                Text("Saves your history, subscriptions, playlists, and Suggest more / less "
                     + "ratings to a JSON file. Export before changing the app's bundle "
                     + "identifier, then import into the new install.")
            }
        }
        .navigationTitle("Backup & Data")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportFile) { ShareSheet(items: [$0.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): importData(url)
            case .failure(let error): backupResult = error.localizedDescription
            }
        }
        .alert("Backup", isPresented: Binding(
            get: { backupResult != nil }, set: { if !$0 { backupResult = nil } })) {
            Button("OK", role: .cancel) { backupResult = nil }
        } message: {
            Text(backupResult ?? "")
        }
    }

    private func exportData() {
        do {
            exportFile = ExportFile(url: try BackupStore.export(from: context))
        } catch {
            backupResult = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importData(_ url: URL) {
        do {
            backupResult = try BackupStore.restore(from: url, into: context).text
        } catch {
            backupResult = "Import failed: \(error.localizedDescription)"
        }
    }
}

/// Wraps the temp backup URL so it can drive a `.sheet(item:)`.
private struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Minimal bridge to the system share sheet for exporting the backup file.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
