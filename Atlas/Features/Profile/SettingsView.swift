import PipedKit
import SwiftUI

/// Drill-down destinations for the heavier settings groups. Kept value-based so
/// they register through ProfileView's central `navigationDestination` switch,
/// matching the rest of the stack — mixing in destination-based links would
/// double-navigate (see the note in ProfileView).
enum SettingsRoute: Hashable {
    case instances
    case sponsorBlock
    case backup
}

/// Root settings screen: the lightweight, frequently-touched controls stay
/// inline; heavier groups (instance, SponsorBlock, backup) drill into their own
/// pages with a summary value shown on the row.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(FeedMode.storageKey) private var feedMode: FeedMode = .subscriptions
    @AppStorage(YouTubeCollaborators.settingKey) private var resolveCollaboratorsViaYouTube = false

    private var currentHost: String {
        guard !app.instanceURLString.isEmpty else { return "Not set" }
        return URL(string: app.instanceURLString)?.host ?? app.instanceURLString
    }

    private var sponsorSummary: String {
        guard app.sponsorBlockEnabled else { return "Off" }
        let enabledCategoryCount = SponsorCategory.allCases.filter {
            app.isSponsorCategoryEnabled($0)
        }.count
        return "\(enabledCategoryCount) on"
    }

    private var privacyNetworkSummary: String {
        let base =
            "Atlas sends API, search, recommendation, and SponsorBlock requests "
            + "to your selected Piped instance. It directly contacts media, image, and "
            + "caption hosts referenced by that instance."
        if resolveCollaboratorsViaYouTube {
            return base + " Collaborator details may also be fetched directly from youtube.com."
        }
        return base + " Direct YouTube collaborator lookup is off."
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var privacyPolicyURL: URL? {
        URL(string: "https://atlas.cmf.sh/privacy")
    }

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Picker("Feed", selection: $feedMode) {
                    ForEach(FeedMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
            } header: {
                Text("Home")
            } footer: {
                Text(feedMode.blurb)
            }

            Section {
                Toggle("Hide Shorts", isOn: $app.hideShorts)
                if !app.hideShorts {
                    Picker("Layout", selection: $app.shortsLayout) {
                        ForEach(ShortsLayout.allCases) { Text($0.label).tag($0) }
                    }
                }
            } header: {
                Text("Content")
            } footer: {
                Text(
                    app.hideShorts
                        ? "Hide YouTube Shorts from your feed, search, and channels."
                        : app.shortsLayout.blurb)
            }

            Section {
                Toggle("Resolve Collaborators via YouTube", isOn: $resolveCollaboratorsViaYouTube)
            } header: {
                Text("Privacy")
            } footer: {
                Text(privacyNetworkSummary)
            }

            Section {
                Picker("Player", selection: $app.playerStyle) {
                    ForEach(PlayerStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Stats for Nerds", isOn: $app.statsForNerdsEnabled)
            } header: {
                Text("Playback")
            } footer: {
                let diagnosticsDescription =
                    "Shows a playback diagnostics button over videos "
                    + "with resolution, codec, stream, buffer, and stall details."
                Text(
                    app.statsForNerdsEnabled
                        ? diagnosticsDescription
                        : app.playerStyle.blurb)
            }

            Section {
                NavigationLink(value: SettingsRoute.instances) {
                    settingRow("Instance", systemImage: "server.rack", detail: currentHost)
                }
                .accessibilityLabel("Instance")
                .accessibilityValue(currentHost)
                NavigationLink(value: SettingsRoute.sponsorBlock) {
                    settingRow(
                        "SponsorBlock", systemImage: "forward",
                        detail: sponsorSummary)
                }
                .accessibilityLabel("SponsorBlock")
                .accessibilityValue(
                    app.sponsorBlockEnabled
                        ? "\(SponsorCategory.allCases.filter { app.isSponsorCategoryEnabled($0) }.count) categories enabled"
                        : "Off")
                NavigationLink(value: SettingsRoute.backup) {
                    Label("Backup & Data", systemImage: "externaldrive")
                }
            }

            Section {
                if let privacyPolicyURL {
                    Link(destination: privacyPolicyURL) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }
                LabeledContent("Version", value: appVersion)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A label with a trailing secondary detail, matching the count rows in ProfileView.
    private func settingRow(_ title: String, systemImage: String, detail: String) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(detail).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

}
