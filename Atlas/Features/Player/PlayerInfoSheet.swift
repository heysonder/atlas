import SwiftUI
import PipedKit

/// The player's "Info" sheet: wraps the shared `PlayerInfoContent` in a sheet
/// chrome (navigation bar + Done). Presented over the still-playing video, so it
/// never interrupts playback. Opens at the medium detent — drag up for comments.
struct PlayerInfoSheet: View {
    let title: String
    let uploader: String?
    let uploaderDisplayName: String?
    let uploaderAvatar: String?
    let channelID: String?
    let creators: [VideoCreator]
    let subscriberCount: Int?
    let uploaderVerified: Bool
    let thumbnail: String?
    let duration: Int?
    let description: String
    let chapters: [VideoChapter]
    let canSubscribe: Bool
    let isSubscribed: Bool
    let onToggleSubscribe: (Bool) -> Void
    /// Only shown when the personalized For You feed is on.
    let showFeedback: Bool
    let feedback: Int
    let onFeedback: (Int) -> Void
    let onQueuedVideoPlay: (QueuedVideo) -> Void
    /// Used to fetch comments lazily once the sheet appears.
    let client: PipedClient
    let videoID: String
    var playbackTime: PlayerPlaybackTime?
    var onTimestampTap: (Int) -> Void = { _ in }
    var onDisappear: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                PlayerInfoContent(
                    title: title, uploader: uploader, uploaderDisplayName: uploaderDisplayName,
                    uploaderAvatar: uploaderAvatar, channelID: channelID,
                    creators: creators,
                    subscriberCount: subscriberCount, uploaderVerified: uploaderVerified,
                    thumbnail: thumbnail, duration: duration,
                    description: description, chapters: chapters,
                    canSubscribe: canSubscribe, isSubscribed: isSubscribed,
                    onToggleSubscribe: onToggleSubscribe, showFeedback: showFeedback,
                    feedback: feedback, onFeedback: onFeedback,
                    onQueuedVideoPlay: onQueuedVideoPlay,
                    client: client, videoID: videoID,
                    currentPlaybackSeconds: playbackTime?.seconds,
                    onTimestampTap: onTimestampTap)
                    .padding()
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                ChannelDetailView(channelID: id)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onDisappear(perform: onDisappear)
    }
}
