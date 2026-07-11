import PipedKit
import SwiftUI

struct SearchResultsContent: View {
    let results: SearchResults
    let videos: [StreamItem]
    let query: String
    let horizontalSizeClass: UserInterfaceSizeClass?
    let isLoadingMore: Bool
    let canLoadMore: Bool
    let loadMoreError: String?
    let onAppearVideo: (StreamItem) -> Void
    let onPlay: (StreamItem) -> Void
    let onLoadMore: () async -> Void
    let onRetryLoadMore: () async -> Void

    var body: some View {
        if results.channels.isEmpty && videos.isEmpty {
            if !results.videos.isEmpty {
                ContentUnavailableView(
                    "Results hidden",
                    systemImage: "eye.slash",
                    description: Text("Matching Shorts are hidden by your Content setting."))
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ChannelSearchResults(
                        channels: results.channels,
                        horizontalSizeClass: horizontalSizeClass)
                    if !results.channels.isEmpty {
                        Color.clear.frame(height: 12)
                    }
                    GroupedVideoList(
                        items: videos,
                        onAppearItem: onAppearVideo,
                        onPlay: onPlay
                    )
                    .onScreenVideos(videos)
                    paginationFooter
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if let loadMoreError {
            VStack(spacing: 8) {
                Label("Couldn’t load more results", systemImage: "wifi.exclamationmark")
                    .font(.callout.weight(.semibold))
                Text(loadMoreError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await onRetryLoadMore() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if isLoadingMore {
            ProgressView()
                .accessibilityLabel("Loading more search results")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else if canLoadMore {
            Color.clear
                .frame(height: 1)
                .id(results.videos.count + results.channels.count)
                .onAppear { Task { await onLoadMore() } }
        }
    }
}

private struct ChannelSearchResults: View {
    let channels: [StreamItem]
    let horizontalSizeClass: UserInterfaceSizeClass?

    private var topChannels: [StreamItem] {
        Array(channels.prefix(3))
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            LazyVGrid(
                columns: LibraryGrid.columns(minCardWidth: 320),
                spacing: LibraryGrid.spacing
            ) {
                channelLinks(useCards: true)
            }
        } else {
            channelLinks(useCards: false)
        }
    }

    @ViewBuilder
    private func channelLinks(useCards: Bool) -> some View {
        ForEach(topChannels) { item in
            if let channelID = item.ownChannelID {
                NavigationLink(value: channelID) {
                    if useCards {
                        ChannelSearchResultRow(item: item).libraryCard()
                    } else {
                        ChannelSearchResultRow(item: item)
                    }
                }
                .buttonStyle(.plain)
                if !useCards {
                    Divider().padding(.leading, 76)
                }
            }
        }
    }
}

private struct ChannelSearchResultRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: StreamItem

    private var metadataLine: String? {
        let subscribers = Format.subscribers(item.subscribers)
        let videoCount: String?
        if let videos = item.videos, videos > 0 {
            videoCount = "\(videos) videos"
        } else {
            videoCount = nil
        }
        let line = Format.metaLine(subscribers, videoCount)
        return line.isEmpty ? nil : line
    }

    var body: some View {
        HStack(spacing: 12) {
            Avatar(
                url: item.thumbnail ?? item.uploaderAvatar,
                size: 52,
                networkScope: .selectedInstance)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                if let metadataLine {
                    Text(metadataLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
