import SwiftUI
import SwiftData

struct ProfileView: View {
    @Query private var subscriptions: [SubscribedChannel]
    @Query private var downloads: [DownloadedVideo]

    /// Value-based routes for the Library menu. Keeping navigation entirely
    /// value-based (rather than mixing in destination-based `NavigationLink`s)
    /// is what prevents the channel-detail push from misbehaving: a stack that
    /// mixes both styles double-navigates (you'd land back on the list and have
    /// to tap "back" to reach the detail).
    private enum Route: Hashable {
        case channels, history, playlists, downloads, settings
    }

    var body: some View {
        NavigationStack {
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
                }
            }
            .navigationDestination(for: String.self) { id in
                ChannelDetailView(channelID: id)
            }
        }
    }
}
