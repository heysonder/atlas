import SwiftUI
import SwiftData
import PipedKit

struct ChannelsView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \SubscribedChannel.name) private var channels: [SubscribedChannel]

    var body: some View {
        Group {
            if channels.isEmpty {
                ContentUnavailableView {
                    Label("No channels yet", systemImage: "person.2")
                } description: {
                    Text("Channels you subscribe to show up here.")
                } actions: {
                    Button("Search") { app.selectedTab = .search }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(channels) { channel in
                        NavigationLink(value: channel.channelID) {
                            HStack(spacing: 12) {
                                Avatar(url: channel.avatarURL, size: 44)
                                Text(channel.name).font(.body.weight(.medium))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Channels")
    }
}
