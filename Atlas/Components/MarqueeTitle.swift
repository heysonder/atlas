import SwiftUI

/// A single-line title that pauses, then loops like the expanded Now Playing title.
/// The two copies share a track so the next title arrives before the first leaves.
/// With "Scrolling Titles" off in Settings it is the plain two-line title instead.
struct MarqueeTitle: View {
    let title: String

    @Environment(AppModel.self) private var app
    @Environment(\.marqueeTitlesEnabled) private var marqueeEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase
    @State private var textWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0
    @State private var isVisible = false

    init(_ title: String) {
        self.title = title
    }

    private var singleLineTitle: String {
        title.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private var shouldScroll: Bool {
        marqueeEnabled && availableWidth > 0 && textWidth > availableWidth + 0.5
            && isVisible && scenePhase == .active && !reduceMotion && !voiceOverEnabled
    }

    @ViewBuilder
    var body: some View {
        if app.scrollingTitlesEnabled {
            marquee
        } else {
            Text(title)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var marquee: some View {
        Text(singleLineTitle)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(shouldScroll ? 0 : 1)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                availableWidth = $0
            }
            .background {
                Text(singleLineTitle)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: {
                        textWidth = $0
                    }
            }
            .overlay(alignment: .leading) {
                if shouldScroll {
                    MarqueeTrack(
                        title: singleLineTitle,
                        textWidth: textWidth,
                        availableWidth: availableWidth,
                        layoutDirection: layoutDirection
                    )
                    // Resizing, Dynamic Type, and reused rows start at the new title's beginning.
                    .id(trackIdentity)
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
    }

    private var trackIdentity: TrackIdentity {
        TrackIdentity(
            title: singleLineTitle, textWidth: textWidth,
            availableWidth: availableWidth, layoutDirection: layoutDirection)
    }

    private struct TrackIdentity: Hashable {
        let title: String
        let textWidth: CGFloat
        let availableWidth: CGFloat
        let layoutDirection: LayoutDirection
    }
}

private struct MarqueeTrack: View {
    let title: String
    let textWidth: CGFloat
    let availableWidth: CGFloat
    let layoutDirection: LayoutDirection

    // Matched to the supplied Dynamic Island recording, in points rather than pixels.
    private let speed: CGFloat = 30
    private let gap: CGFloat = 36
    private let pause: TimeInterval = 3
    nonisolated private var distance: CGFloat { textWidth + gap }

    var body: some View {
        HStack(spacing: gap) {
            Text(title)
            Text(title)
        }
        .lineLimit(1)
        .fixedSize()
        .keyframeAnimator(initialValue: CGFloat.zero) { content, offset in
            content
                .offset(x: layoutDirection == .rightToLeft ? offset : -offset)
                .frame(width: availableWidth, alignment: .leading)
                .mask { edgeFade(offset: offset) }
        } keyframes: { _ in
            LinearKeyframe(0, duration: pause)
            LinearKeyframe(distance, duration: Double(distance / speed))
            MoveKeyframe(0)
        }
        .accessibilityHidden(true)
    }

    nonisolated private func edgeFade(offset: CGFloat) -> some View {
        let fadeWidth = min(12, availableWidth / 4)
        let leadingFade = min(1, min(offset, distance - offset) / fadeWidth)
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(1 - Double(leadingFade)), location: 0),
                .init(color: .black, location: fadeWidth / availableWidth),
                .init(color: .black, location: 1 - fadeWidth / availableWidth),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }
}

extension EnvironmentValues {
    /// Lets a container hold titles still until something happens — the
    /// embedded watch page keeps them static until the reader scrolls.
    @Entry var marqueeTitlesEnabled = true
}

#Preview("Feed titles") {
    VStack(alignment: .leading, spacing: 24) {
        MarqueeTitle("Can We Guess Our Crew Based On Their Top Emojis? (Phone It In)")
        MarqueeTitle("A short title")
        MarqueeTitle("A long title stays on one line at larger text sizes")
            .dynamicTypeSize(.accessibility3)
    }
    .font(.subheadline.weight(.semibold))
    .padding()
    .environment(AppModel())
}
