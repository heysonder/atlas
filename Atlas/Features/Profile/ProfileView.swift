import SwiftData
import SwiftUI

/// The Library tab. A `NavigationSplitView`: at regular width the sections
/// are a sidebar with the selected one (History by default) filling the
/// detail column, so an iPad never opens onto an empty menu; in compact width
/// the split view collapses into the familiar list-then-push stack on its own.
struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query private var subscriptions: [SubscribedChannel]
    @Query private var downloads: [DownloadedVideo]

    @State private var selection: Route?
    // Type-erased so the detail stack can hold more than one value type: it
    // pushes `SettingsRoute` (Settings sub-screens) and `String` (a channel
    // id, from ChannelsView). A typed path silently drops any other push —
    // the row highlights but never navigates.
    @State private var detailPath = NavigationPath()

    /// Value-based routes for the Library sections. Keeping navigation
    /// value-based (rather than mixing in destination-based `NavigationLink`s
    /// at this level) is what keeps the channel-detail push from
    /// double-navigating.
    private enum Route: Hashable {
        case channels, history, playlists, downloads, settings
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    NavigationLink(value: Route.channels) {
                        Label {
                            HStack {
                                Text("Channels")
                                Spacer()
                                if !subscriptions.isEmpty {
                                    Text("\(subscriptions.count)").foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "person.2")
                        }
                    }
                    .accessibilityLabel("Channels")
                    .accessibilityValue(
                        subscriptions.isEmpty
                            ? "No subscribed channels"
                            : "\(subscriptions.count) subscribed channels")
                    NavigationLink(value: Route.history) {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink(value: Route.playlists) {
                        Label("Playlists", systemImage: "music.note.list")
                    }
                    NavigationLink(value: Route.downloads) {
                        Label {
                            HStack {
                                Text("Downloads")
                                Spacer()
                                if !downloads.isEmpty {
                                    Text("\(downloads.count)").foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                    .accessibilityLabel("Downloads")
                    .accessibilityValue(
                        downloads.isEmpty
                            ? "No downloaded videos"
                            : "\(downloads.count) downloaded videos")
                }
                Section {
                    NavigationLink(value: Route.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Library")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            NavigationStack(path: $detailPath) {
                detailRoot
                    .navigationDestination(for: SettingsRoute.self) { route in
                        switch route {
                        case .instances: InstancesSettingsView()
                        case .sponsorBlock: SponsorBlockSettingsView()
                        case .backup: BackupSettingsView()
                        case .iCloudSync: ICloudSyncSettingsView()
                        case .diagnostics: DiagnosticsSettingsView()
                        }
                    }
                    .navigationDestination(for: String.self) { id in
                        ChannelDetailView(channelID: id)
                    }
            }
        }
        // A sidebar with nothing selected is the only empty screen in the app;
        // in compact width `nil` correctly means "show the list".
        .onAppear { selectDefaultIfNeeded() }
        .onChange(of: horizontalSizeClass) { _, _ in selectDefaultIfNeeded() }
        // Deep-link from Siri / "Open Downloads": select the section and push
        // anything beneath it. Handles both the warm case (onChange) and a cold
        // launch (onAppear).
        .onAppear { applyLibraryTarget() }
        .onChange(of: app.libraryTarget) { _, _ in applyLibraryTarget() }
    }

    @ViewBuilder private var detailRoot: some View {
        switch selection ?? .history {
        case .channels: ChannelsView()
        case .history: HistoryView()
        case .playlists: PlaylistsView()
        case .downloads: DownloadsView()
        case .settings: SettingsView()
        }
    }

    private func selectDefaultIfNeeded() {
        if horizontalSizeClass == .regular, selection == nil {
            selection = .history
        }
    }

    /// Honors a pending `AppModel.libraryTarget`, then clears it.
    private func applyLibraryTarget() {
        guard let target = app.libraryTarget else { return }
        app.libraryTarget = nil
        var path = NavigationPath()
        switch target {
        case .downloads: selection = .downloads
        case .history: selection = .history
        case .playlists: selection = .playlists
        case .channel(let channelID):
            selection = .channels
            path.append(channelID)
        case .instanceSettings:
            selection = .settings
            path.append(SettingsRoute.instances)
        }
        detailPath = path
    }
}
