import SwiftUI
import PipedKit

/// The SponsorBlock master switch plus per-category skip toggles.
struct SponsorBlockSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Toggle("SponsorBlock", isOn: $app.sponsorBlockEnabled)
                if app.sponsorBlockEnabled {
                    ForEach(SponsorCategory.allCases) { category in
                        Toggle(category.label, isOn: categoryBinding(category))
                    }
                }
            } footer: {
                Text("Crowdsourced segment data from your Piped instance. A “Skip” button "
                     + "appears over the video when an enabled segment plays — tap it to jump past.")
            }
        }
        .navigationTitle("SponsorBlock")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func categoryBinding(_ category: SponsorCategory) -> Binding<Bool> {
        Binding(
            get: { app.isSponsorCategoryEnabled(category) },
            set: { app.setSponsorCategory(category, enabled: $0) })
    }
}
