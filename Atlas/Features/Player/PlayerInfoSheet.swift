import PipedKit
import SwiftUI

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
    let onToggleSubscribe: (Bool) -> Bool
    /// Only shown when the personalized For You feed is on.
    let showFeedback: Bool
    let feedback: Int
    let onFeedback: (Int) -> Bool
    let onQueuedVideoPlay: (QueuedVideo) -> Void
    /// Used to fetch comments lazily once the sheet appears.
    let client: PipedClient
    let videoID: String
    var playbackTime: PlayerPlaybackTime?
    var onTimestampTap: (Int) -> Void = { _ in }
    var onDisappear: () -> Void = {}

    /// Wide viewports dock the sheet as a trailing side panel over the
    /// still-playing video instead of a bottom sheet (see `PlayerInfoSidePanel`).
    var asSidePanel = false

    @Environment(\.dismiss) private var dismiss
    @State private var panelShown = false

    private static let panelWidth: CGFloat = 420

    var body: some View {
        if asSidePanel {
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .accessibilityLabel("Close info")
                if panelShown {
                    stack
                        .frame(width: Self.panelWidth)
                        .frame(maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.vertical, 12)
                        .padding(.trailing, 12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onAppear { withAnimation(.snappy(duration: 0.3)) { panelShown = true } }
            .onDisappear(perform: onDisappear)
        } else {
            stack.onDisappear(perform: onDisappear)
        }
    }

    private var stack: some View {
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
                    onTimestampTap: onTimestampTap
                )
                .padding()
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            // Keep the hosted content transparent so the sheet's Liquid Glass
            // background (medium detent) shows through, like Maps.
            .containerBackground(.clear, for: .navigation)
            .navigationDestination(for: String.self) { id in
                ChannelDetailView(channelID: id)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
