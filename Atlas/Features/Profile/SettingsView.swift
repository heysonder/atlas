import DeclaredAgeRange
import PipedKit
import SwiftData
import SwiftUI

/// Drill-down destinations for the heavier settings groups. Kept value-based so
/// they register through ProfileView's central `navigationDestination` switch,
/// matching the rest of the stack — mixing in destination-based links would
/// double-navigate (see the note in ProfileView).
enum SettingsRoute: Hashable {
    case instances
    case sponsorBlock
    case backup
    case iCloudSync
    case diagnostics
}

/// Root settings screen: the lightweight, frequently-touched controls stay
/// inline; heavier groups (instance, SponsorBlock, backup) drill into their own
/// pages with a summary value shown on the row.
struct SettingsView: View {
    /// Player style + Stats for Nerds are developer knobs; hidden for now.
    private static let showsPlayerOptions = false

    @Environment(AppModel.self) private var app
    @Environment(CloudSyncCoordinator.self) private var sync
    @Environment(\.modelContext) private var context
    @AppStorage(FeedMode.storageKey) private var feedMode: FeedMode = .subscriptions
    @AppStorage(YouTubeCollaborators.settingKey) private var resolveCollaboratorsViaYouTube = false
    @Environment(\.requestAgeRange) private var requestAgeRange
    private var socialGate: SocialFeaturesGate { SocialFeaturesGate.shared }

    private var socialSummary: String {
        switch socialGate.status {
        case .allowed: "On"
        case .underage: "Off (under 13)"
        case .declined: "Off (not shared)"
        case .unknown: "Not checked"
        }
    }

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

    /// On/Off at rest; the live status while a round or deletion runs, when
    /// something needs attention, or after a deletion completes, so leaving the
    /// sync page loses nothing.
    private var syncRowDetail: String {
        switch sync.tone {
        case .working, .attention: sync.statusText
        case .healthy where sync.isEnabled: "On"
        case .healthy where sync.showsDetail: sync.statusText
        case .healthy, .off: "Off"
        }
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
                Picker(
                    "Feed",
                    selection: Binding(
                        get: { feedMode },
                        set: { SyncPreferences.set(key: FeedMode.storageKey, value: $0.rawValue, in: context) }
                    )
                ) {
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

            if SocialFeaturesGate.isEnforced {
                Section {
                    LabeledContent("Comments & Chat", value: socialSummary)
                    Button("Check Age Range") {
                        Task { await socialGate.resolve(using: requestAgeRange, force: true) }
                    }
                    .disabled(socialGate.isChecking)
                } header: {
                    Text("Social Features")
                } footer: {
                    Text(
                        "Comments, live chat, and chat replay are user-generated content and are only shown to users 13 or older, "
                            + "based on the age range declared for your Apple Account. Only the result (on or off) is stored on this device."
                    )
                }
            }

            if Self.showsPlayerOptions {
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
                NavigationLink(value: SettingsRoute.iCloudSync) {
                    settingRow("iCloud Sync", systemImage: "icloud", detail: syncRowDetail)
                }
                .accessibilityLabel("iCloud Sync")
                .accessibilityValue(sync.statusText)
                NavigationLink(value: SettingsRoute.diagnostics) {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
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
