import SwiftUI

/// Picking the Piped API instance: shows the current one and lets you point
/// Atlas at a custom (ideally self-hosted) instance.
///
/// The old "Public instances" list was removed deliberately — the public Piped
/// instances are unreliable (frequently empty `relatedStreams`, broken
/// extraction, downtime), so surfacing a list of them only invited people to
/// pick a broken one. Self-hosting (or a known-good custom URL) is the path.
struct InstancesSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var customURL = ""

    var body: some View {
        Form {
            Section("Current instance") {
                Text(currentInstanceLabel)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                TextField("https://your-instance.example", text: $customURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Use this instance") { useCustom() }
                    .disabled(!isCustomURLValid)
            } header: {
                Text("Custom instance")
            } footer: {
                Text("Point Atlas at your own HTTPS self-hosted Piped API for the most reliable experience.")
            }
        }
        .navigationTitle("Instance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentInstanceLabel: String {
        app.instanceURLString.isEmpty ? "Not set" : app.instanceURLString
    }

    private var isCustomURLValid: Bool {
        AppModel.isValidInstanceURL(customURL)
    }

    private func useCustom() {
        let normalized = AppModel.normalize(customURL)
        guard AppModel.isValidInstanceURL(normalized) else { return }
        app.instanceURLString = normalized
        customURL = ""
    }
}
