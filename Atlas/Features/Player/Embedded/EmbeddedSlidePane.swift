import SwiftUI

/// A pane that slides up over the watch page beneath the embedded player —
/// the full comment list or the live chat. A grabber and a close button sit
/// on top; dragging the header, or pulling down when the content is already
/// at the top, dismisses it.
struct EmbeddedSlidePane<Content: View>: View {
    let title: String
    let countText: String?
    let closeLabel: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The live drag offset sits in an observable box read only by
    /// `EmbeddedSlidePaneOffset`, so a drag moves the pane without re-running
    /// this body and rebuilding the comment list on every finger movement.
    @State private var drag = EmbeddedSlidePaneDrag()
    @State private var contentAtTop = true
    @State private var pullingContent = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .gesture(dismissDrag)
            Divider()
            content()
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y <= geometry.contentInsets.top + 1
                } action: { _, atTop in
                    contentAtTop = atTop
                }
                .scrollDisabled(pullingContent)
                .simultaneousGesture(contentPullDrag)
        }
        .clipShape(Self.shape)
        // The shadow is cast by the background shape alone; on the clipped
        // pane it was re-rendered from the whole list on every scroll frame.
        .background {
            Self.shape
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.18), radius: 14, y: -4)
        }
        .modifier(EmbeddedSlidePaneOffset(drag: drag))
        .ignoresSafeArea(edges: .bottom)
    }

    private static var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20, style: .continuous)
    }

    private static var headerDragDistance: CGFloat { 4 }
    private static var contentPullDistance: CGFloat { 12 }

    private var header: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let countText {
                    Text(countText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel(closeLabel)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .contentShape(Rectangle())
    }

    /// Dragging the header always moves the pane. Both drags are measured
    /// in global space: the pane moves under the finger, so a local
    /// translation shifts with it and the offset oscillates. They also start
    /// from the recognition threshold, so the pane leaves from rest instead
    /// of hopping by that distance.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: Self.headerDragDistance, coordinateSpace: .global)
            .onChanged { value in
                drag.offset = max(value.translation.height - Self.headerDragDistance, 0)
            }
            .onEnded { value in finishDrag(value) }
    }

    /// Pulling the content down past its top edge takes over from the scroll
    /// view and moves the pane instead, so "swipe down to go back" works
    /// from anywhere in the list.
    private var contentPullDrag: some Gesture {
        DragGesture(minimumDistance: Self.contentPullDistance, coordinateSpace: .global)
            .onChanged { value in
                let dy = value.translation.height
                if !pullingContent {
                    guard contentAtTop, dy > 0, dy > abs(value.translation.width) else { return }
                    pullingContent = true
                }
                drag.offset = max(dy - Self.contentPullDistance, 0)
            }
            .onEnded { value in
                guard pullingContent else { return }
                pullingContent = false
                finishDrag(value)
            }
    }

    private func finishDrag(_ value: DragGesture.Value) {
        if value.translation.height > 120 || value.predictedEndTranslation.height > 300 {
            onClose()
        } else if reduceMotion {
            drag.offset = 0
        } else {
            withAnimation(.snappy(duration: 0.3)) { drag.offset = 0 }
        }
    }
}

@Observable
final class EmbeddedSlidePaneDrag {
    var offset: CGFloat = 0
}

/// The only reader of the drag offset: just this modifier re-evaluates while
/// the finger moves.
private struct EmbeddedSlidePaneOffset: ViewModifier {
    let drag: EmbeddedSlidePaneDrag

    func body(content: Content) -> some View {
        content.offset(y: drag.offset)
    }
}
