import SwiftUI

/// Drives the in-player "Info" button. While the video plays the button shows
/// just the ⓘ glyph; when the coordinator sets `isPaused` it expands to reveal
/// the "Info" label, matching the more discoverable controls-visible state.
@MainActor
@Observable
final class InfoButtonModel {
    var isPaused = false
    @ObservationIgnored var onTap: () -> Void = {}
}

/// Drives the in-player "Chat" button: hidden unless the video is live or a
/// chat replay was found; expands like the Info button when paused.
@MainActor
@Observable
final class ChatButtonModel {
    var isVisible = false
    var isLive = false
    var isPaused = false
    @ObservationIgnored var onTap: () -> Void = {}
}

@MainActor
@Observable
final class PlayerPlaybackTime {
    var seconds: Double?
}

/// Geometry shared by every control layered over the video, so the top-right
/// Info/Chat cluster and the bottom-right Skip pill sit on one trailing line
/// with one height and one padding.
enum PlayerOverlayLayout {
    static let buttonHeight: CGFloat = 44
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 9
    static let spacing: CGFloat = 8
    /// From the safe area's top edge and from the physical trailing edge —
    /// iPhones report the same ~59pt landscape inset on both sides, so
    /// honoring it here left the buttons floating far from the corner.
    static let edgeInset: CGFloat = 12
    /// Skip's distance from the safe area's bottom edge — clears the scrubber.
    static let skipBottomInset: CGFloat = 56
    /// Stable width the Skip host reserves so the pill can animate in place.
    static let skipReservedWidth: CGFloat = 240
}

/// The small Liquid Glass "Info" button layered over the video.
struct InfoOverlayButton: View {
    let model: InfoButtonModel
    /// Reserve the expanded ("Info" label) width so the button doesn't slide
    /// when it expands. Off inside `PlayerOverlayButtons`, which reserves for
    /// the whole cluster instead.
    var reservesExpandedWidth = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let expandedFootprintWidth: CGFloat = 88

    var body: some View {
        Button(action: model.onTap) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                if model.isPaused {
                    Text("Info")
                        .transition(.blurReplace)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, model.isPaused ? PlayerOverlayLayout.horizontalPadding : 10)
            .padding(.vertical, PlayerOverlayLayout.verticalPadding)
            .frame(minWidth: PlayerOverlayLayout.buttonHeight, minHeight: PlayerOverlayLayout.buttonHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .frame(minWidth: reservesExpandedWidth ? Self.expandedFootprintWidth : nil, alignment: .trailing)
        .accessibilityLabel("Info")
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: model.isPaused)
    }
}

/// The top-trailing cluster over the video: Chat (when available) then Info.
struct PlayerOverlayButtons: View {
    let info: InfoButtonModel
    let chat: ChatButtonModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: PlayerOverlayLayout.spacing) {
            if chat.isVisible {
                ChatOverlayButton(model: chat)
                    .transition(.blurReplace)
            }
            InfoOverlayButton(model: info, reservesExpandedWidth: false)
        }
        // Reserve the expanded width for the cluster so neither button slides
        // when the labels appear on pause; the buttons themselves stay snug.
        .frame(
            minWidth: chat.isVisible
                ? InfoOverlayButton.expandedFootprintWidth * 2 + PlayerOverlayLayout.spacing
                : InfoOverlayButton.expandedFootprintWidth,
            alignment: .trailing
        )
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: chat.isVisible)
    }
}

/// Liquid Glass "Chat" button; a red dot marks a live stream.
struct ChatOverlayButton: View {
    let model: ChatButtonModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: model.onTap) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .overlay(alignment: .topTrailing) {
                        if model.isLive {
                            Circle().fill(.red).frame(width: 6, height: 6).offset(x: 3, y: -3)
                        }
                    }
                if model.isPaused {
                    Text("Chat").transition(.blurReplace)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, model.isPaused ? PlayerOverlayLayout.horizontalPadding : 10)
            .padding(.vertical, PlayerOverlayLayout.verticalPadding)
            .frame(minWidth: PlayerOverlayLayout.buttonHeight, minHeight: PlayerOverlayLayout.buttonHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel(model.isLive ? "Live chat" : "Chat replay")
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: model.isPaused)
    }
}
