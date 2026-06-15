import SwiftUI
import SwiftData

struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @Query private var subscriptions: [SubscribedChannel]
    @Query private var downloads: [DownloadedVideo]
    // Type-erased so the stack can hold more than one value type. The Library
    // pushes `Route` (top-level menu), `SettingsRoute` (Settings sub-screens),
    // and `String` (a channel id, from ChannelsView). A typed `[Route]` path
    // silently drops any non-`Route` push — the row highlights but never
    // navigates — which is why tapping a channel here used to do nothing while
    // the same channel link works from Feed/Search (those stacks are untyped).
    @State private var path = NavigationPath()

    /// Value-based routes for the Library menu. Keeping navigation entirely
    /// value-based (rather than mixing in destination-based `NavigationLink`s)
    /// is what prevents the channel-detail push from misbehaving: a stack that
    /// mixes both styles double-navigates (you'd land back on the list and have
    /// to tap "back" to reach the detail).
    private enum Route: Hashable {
        case channels, history, playlists, downloads, settings
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
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
                }
                Section {
                    NavigationLink(value: Route.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .channels: ChannelsView()
                case .history: HistoryView()
                case .playlists: PlaylistsView()
                case .downloads: DownloadsView()
                case .settings: SettingsView()
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .instances: InstancesSettingsView()
                case .sponsorBlock: SponsorBlockSettingsView()
                case .backup: BackupSettingsView()
                case .topicCloud: TopicCloudView()
                }
            }
            .navigationDestination(for: String.self) { id in
                ChannelDetailView(channelID: id)
            }
        }
        // Deep-link from Siri / "Open Downloads": push the requested sub-screen.
        .onAppear { applyLibraryTarget() }
        .onChange(of: app.libraryTarget) { _, _ in applyLibraryTarget() }
    }

    /// Honors a pending `AppModel.libraryTarget` by pushing its route, then clears
    /// it. Handles both the warm case (onChange) and a cold launch (onAppear).
    private func applyLibraryTarget() {
        guard let target = app.libraryTarget else { return }
        app.libraryTarget = nil
        switch target {
        case .downloads: path = NavigationPath([Route.downloads])
        case .history: path = NavigationPath([Route.history])
        case .playlists: path = NavigationPath([Route.playlists])
        }
    }
}
