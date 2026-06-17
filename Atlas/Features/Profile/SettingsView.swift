import SwiftUI
import PipedKit

/// Drill-down destinations for the heavier settings groups. Kept value-based so
/// they register through ProfileView's central `navigationDestination` switch,
/// matching the rest of the stack — mixing in destination-based links would
/// double-navigate (see the note in ProfileView).
enum SettingsRoute: Hashable {
    case instances, sponsorBlock, backup, topicCloud
}

/// Root settings screen: the lightweight, frequently-touched controls stay
/// inline; heavier groups (instance, SponsorBlock, backup) drill into their own
/// pages with a summary value shown on the row.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("feedMode") private var feedMode: FeedMode = .subscriptions

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
                Text(app.hideShorts
                     ? "Hide YouTube Shorts from your feed, search, and channels."
                     : app.shortsLayout.blurb)
            }

            Section {
                NavigationLink(value: SettingsRoute.topicCloud) {
                    settingRow("Topic Cloud", systemImage: "textformat.size", detail: "Local")
                }
            } header: {
                Text("Personalization")
            }

            Section {
                Picker("Player", selection: $app.playerStyle) {
                    ForEach(PlayerStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Stats for Nerds", isOn: $app.statsForNerdsEnabled)
            } header: {
                Text("Playback")
            } footer: {
                Text(app.statsForNerdsEnabled
                     ? "Shows a playback diagnostics button over videos with resolution, codec, stream, buffer, and stall details."
                     : app.playerStyle.blurb)
            }

            Section {
                NavigationLink(value: SettingsRoute.instances) {
                    settingRow("Instance", systemImage: "server.rack", detail: currentHost)
                }
                NavigationLink(value: SettingsRoute.sponsorBlock) {
                    settingRow("SponsorBlock", systemImage: "forward",
                               detail: sponsorSummary)
                }
                NavigationLink(value: SettingsRoute.backup) {
                    Label("Backup & Data", systemImage: "externaldrive")
                }
            }

            Section {
                Link(destination: privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
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

    private var currentHost: String {
        guard !app.instanceURLString.isEmpty else { return "Not set" }
        return URL(string: app.instanceURLString)?.host ?? app.instanceURLString
    }

    private var sponsorSummary: String {
        guard app.sponsorBlockEnabled else { return "Off" }
        let n = SponsorCategory.allCases.filter { app.isSponsorCategoryEnabled($0) }.count
        return "\(n) on"
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var privacyPolicyURL: URL {
        URL(string: "https://atlas.cmf.sh/privacy")!
    }
}
