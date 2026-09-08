import PipedKit
import SwiftUI

/// The player's "Info" sheet: wraps the shared `PlayerInfoContent` in a sheet
/// chrome (navigation bar + Done). Presented over the still-playing video, so it
/// never interrupts playback. Portrait opens a bottom sheet at the medium detent
/// (drag up for comments); landscape shows the same view as a Maps-style
/// floating glass card docked under the Info button (`asSideCard`).
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

    /// Landscape: a floating glass card docked to the trailing edge under the
    /// Info button, over the still-playing video, instead of a bottom sheet.
    /// Hand-rolled to match the system look (Maps, Fitness) because neither
    /// `UISheetPresentationController.preferredPlacement` nor SwiftUI's
    /// `presentationPlacement` takes effect in compact height on iOS 27.
    var asSideCard = false

    @Environment(\.dismiss) private var dismiss
    @State private var cardShown = false
    @State private var dragOffset: CGFloat = 0

    private static let cardWidth: CGFloat = 440
    private static let cardCornerRadius: CGFloat = 34

    var body: some View {
        if asSideCard {
            sideCard
        } else {
            stack.onDisappear(perform: onDisappear)
        }
    }

    // MARK: Landscape side card

    private var sideCard: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { closeCard() }
                .accessibilityLabel("Close info")
            if cardShown {
                card
                    // Grows out of the Info button, which sits at the card's
                    // top-trailing corner.
                    .transition(.scale(scale: 0.15, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .onAppear { withAnimation(.snappy(duration: 0.35)) { cardShown = true } }
        .onDisappear(perform: onDisappear)
    }

    private var card: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: Self.cardCornerRadius, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: Self.cardCornerRadius,
            style: .continuous)
        return VStack(spacing: 0) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .padding(.top, 6)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .accessibilityLabel("Close info")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { closeCard() }
            stack
        }
        .frame(width: Self.cardWidth)
        .frame(maxHeight: .infinity)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .padding(.top, 8)
        .padding(.trailing, 8)
        .offset(y: dragOffset)
        // The scroll view keeps its own drags; this catches the grabber and
        // title bar so the card can be pulled down to close like a sheet.
        .gesture(dragToDismiss)
        .ignoresSafeArea(edges: .bottom)
    }

    private var dragToDismiss: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 260 {
                    closeCard()
                } else {
                    withAnimation(.snappy(duration: 0.3)) { dragOffset = 0 }
                }
            }
    }

    private func closeCard() {
        withAnimation(.snappy(duration: 0.25)) { cardShown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { dismiss() }
    }

    // MARK: Shared content

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
                    Button("Done") {
                        if asSideCard { closeCard() } else { dismiss() }
                    }
                }
            }
        }
    }
}
