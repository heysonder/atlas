import PipedKit
import SwiftUI

/// The player's "Info" sheet: wraps the shared `PlayerInfoContent` in a sheet
/// chrome (navigation bar + Done). Presented over the still-playing video, so it
/// never interrupts playback. Portrait opens a bottom sheet at the medium detent
/// (drag up for comments); landscape shows the same view in a `PlayerSideCard`
/// docked to the trailing edge (`asSideCard`).
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
    /// Side card only: fires as the card starts animating out.
    var onWillDismiss: () -> Void = {}
    /// Side card only: see `PlayerSideCard.bottomSafeInset`.
    var sideCardBottomInset: CGFloat = 0

    /// Landscape: a side card docked to the trailing edge over the
    /// still-playing video instead of a bottom sheet. Hand-rolled because
    /// neither `UISheetPresentationController.preferredPlacement` nor SwiftUI's
    /// `presentationPlacement` takes effect in compact height on iOS 27.
    var asSideCard = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if asSideCard {
            PlayerSideCard(
                width: 400, closeLabel: "Close info", bottomSafeInset: sideCardBottomInset,
                onWillClose: onWillDismiss, onDisappear: onDisappear
            ) { close in
                page(onDone: close)
            }
        } else {
            page(onDone: { dismiss() }).onDisappear(perform: onDisappear)
        }
    }

    // MARK: Shared content

    private func page(onDone: @escaping () -> Void) -> some View {
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
                    Button("Done", action: onDone)
                }
            }
        }
    }
}
