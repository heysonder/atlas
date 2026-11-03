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
    @State private var dragOffset: CGFloat = 0
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
        .background(Color(.systemBackground))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: -4)
        .offset(y: dragOffset)
        .ignoresSafeArea(edges: .bottom)
    }

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

    /// Dragging the header always moves the pane.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                dragOffset = max(value.translation.height, 0)
            }
            .onEnded { value in finishDrag(value) }
    }

    /// Pulling the content down past its top edge takes over from the scroll
    /// view and moves the pane instead, so "swipe down to go back" works
    /// from anywhere in the list.
    private var contentPullDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let dy = value.translation.height
                if !pullingContent {
                    guard contentAtTop, dy > 0, dy > abs(value.translation.width) else { return }
                    pullingContent = true
                }
                dragOffset = max(dy, 0)
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
            dragOffset = 0
        } else {
            withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
        }
    }
}
