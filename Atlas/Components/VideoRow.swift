import PipedKit
import SwiftUI

/// A YouTube-style video row: thumbnail with duration pill, title, and meta line.
/// Tapping the thumbnail/title plays; tapping the avatar/channel name opens the
/// channel (via a NavigationLink, so the enclosing stack must register a
/// `navigationDestination(for: String.self)` mapping the channel id).
struct VideoRow: View {
    @Environment(AppModel.self) private var app

    let item: StreamItem
    /// Used when the item itself carries no uploader avatar (e.g. a channel page).
    var avatarFallback: String? = nil
    /// Channel id to use when the item carries no uploader url (e.g. a channel page).
    var channelIDFallback: String? = nil
    /// Marks the thumbnail as already watched (dimmed, with a "Watched" badge).
    var watched: Bool = false
    /// Lets a parent that already verified a current livestream avoid repeating
    /// the metadata request and present the live state immediately.
    var liveStatusOverride: Bool? = nil
    var onPlay: () -> Void
    @AppStorage(YouTubeCollaborators.settingKey) private var resolveCollaboratorsViaYouTube = false
    @State private var collaborators: [CreatorChannel] = []
    @State private var resolvedIsLive: Bool?
    /// Stream start from `/streams` — list rows carry no usable start time.
    @State private var resolvedStartMillis: Int64?
    /// Avatar looked up by channel id when the item carries none.
    @State private var resolvedAvatar: String?

    private var channelID: String? { item.uploaderChannelID ?? channelIDFallback }
    private var isLive: Bool {
        liveStatusOverride ?? (item.isLive || resolvedIsLive == true)
    }
    private var creator: CreatorSummary {
        CreatorSummary(
            primaryName: item.uploaderName,
            avatarURL: item.uploaderAvatar ?? avatarFallback ?? resolvedAvatar,
            channelID: channelID,
            isVerified: item.uploaderVerified ?? false,
            collaborators: collaborators)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onPlay) {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            Thumbnail(url: item.thumbnail, networkScope: .selectedInstance)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .imageEdge(RoundedRectangle(cornerRadius: 14, style: .continuous), url: item.thumbnail)
                                .opacity(watched ? 0.55 : 1)
                                .shadow(color: .black.opacity(0.16), radius: 5, x: 0, y: 2)
                                // Bottom-leading, opposite the duration pill.
                                .overlay(alignment: .bottomLeading) {
                                    if watched { WatchedBadge().padding(8) }
                                }
                        }
                    playbackStatePill
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.displayTitle)
            .accessibilityValue(playbackAccessibilityValue)

            HStack(alignment: .top, spacing: 10) {
                CreatorChannelControl(summary: creator) {
                    CreatorAvatarCluster(
                        avatarURL: creator.avatarURL,
                        collaboratorAvatarURLs: creator.collaborators.map(\.avatarURL),
                        additionalCount: creator.additionalCount,
                        size: 34)
                }
                VStack(alignment: .leading, spacing: 3) {
                    title
                    metaRow
                }
                Spacer(minLength: 0)
            }
        }
        .task(id: item.videoID) {
            resolvedIsLive = nil
            resolvedStartMillis = nil
            resolvedAvatar = nil
            await resolveAvatarIfMissing()
            await loadResolvedMetadataIfNeeded()
        }
    }

    private var title: some View {
        Button(action: onPlay) {
            Text(item.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var playbackStatePill: some View {
        let d = Format.duration(item.duration)
        if isLive {
            LiveBadge()
                .padding(8)
        } else if !d.isEmpty {
            ThumbnailChip {
                Text(d)
            }
            .padding(8)
        }
    }

    /// "639 views · 2 days ago", or just "2 days ago" when the video has fewer
    /// than 500 views (the count is noise at that scale). Live rows instead read
    /// "8.8K watching · Started 2 hours ago".
    private var metaText: String {
        if isLive {
            return Format.liveMetaLine(watching: item.views, startedMillis: resolvedStartMillis)
        }
        let timeAgo = Format.relativeTime(item.uploaded) ?? item.uploadedDate
        let viewsStr = (item.views ?? -1) >= 500 ? Format.views(item.views) : nil
        return Format.metaLine(viewsStr, timeAgo)
    }

    @ViewBuilder private var metaRow: some View {
        let meta = metaText
        let rowCreator = creator
        HStack(spacing: 4) {
            if let name = rowCreator.visibleName, !name.isEmpty {
                CreatorChannelControl(summary: rowCreator) {
                    Text(name)
                }
                .accessibilityHidden(rowCreator.hasMultipleCreators || rowCreator.channelID != nil)
                if !meta.isEmpty {
                    Text("·")
                    Text(meta)
                }
            } else if !meta.isEmpty {
                Text(meta)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var playbackAccessibilityValue: String {
        var values: [String] = []
        if watched { values.append("Watched") }
        if isLive {
            values.append("Live")
        } else {
            let duration = Format.duration(item.duration)
            if !duration.isEmpty { values.append("Duration \(duration)") }
        }
        if item.isShort == true { values.append("Short") }
        return values.joined(separator: ", ")
    }

    private func loadResolvedMetadataIfNeeded() async {
        let shouldLoadCollaborators = collaborators.isEmpty && creator.hasMultipleCreators
        let shouldResolveLiveStatus = liveStatusOverride == nil && item.needsLiveStatusResolution
        let shouldResolveStartTime = isLive && resolvedStartMillis == nil
        guard shouldLoadCollaborators || shouldResolveLiveStatus || shouldResolveStartTime,
            let videoID = item.videoID
        else { return }
        guard let detail = try? await app.resolveStreamThrottled(videoID) else { return }

        if shouldResolveLiveStatus {
            resolvedIsLive = detail.livestream == true
        }
        if isLive, let started = detail.uploaded, started > 0 {
            resolvedStartMillis = started
        }

        if shouldLoadCollaborators {
            var loaded =
                detail.creators?.creatorChannels(
                    verifiedChannelID: detail.channelID,
                    uploaderVerified: detail.uploaderVerified ?? false) ?? []

            // The direct-to-YouTube scrape is opt-in; the Piped-side creators
            // above are always fine to use.
            if resolveCollaboratorsViaYouTube,
                loaded.needsCreatorFallback(expectedAdditionalCount: creator.additionalCount)
            {
                loaded = loaded.enriched(with: await YouTubeCollaborators.channels(for: videoID))
            }

            if !loaded.isEmpty {
                collaborators = loaded
            }
        }
    }
}

extension VideoRow {
    /// Rows without an avatar URL resolve one by channel id (cached across
    /// launches); rows that have one seed that cache for everyone else.
    fileprivate func resolveAvatarIfMissing() async {
        guard let channelID else { return }
        let resolver = ChannelAvatarResolver.shared
        if let avatar = item.uploaderAvatar ?? avatarFallback {
            await resolver.record(channelID: channelID, avatarURL: avatar)
            return
        }
        if let cached = await resolver.cached(channelID) {
            resolvedAvatar = cached
            return
        }
        guard let client = try? app.client else { return }
        let avatar = await resolver.avatar(for: channelID, client: client)
        guard !Task.isCancelled else { return }
        resolvedAvatar = avatar
    }
}
