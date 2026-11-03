import SwiftUI

/// A slim floating replacement for the system tab bar: three glyphs in one
/// clear-glass pill, with a lighter capsule that slides behind the selected
/// one. The system bar's height is fixed by iOS; this one is the height of
/// its icons plus a little padding.
struct CompactTabBar: View {
    @Binding var selection: AppModel.TabSelection

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selector

    private struct TabItem: Identifiable {
        let id: AppModel.TabSelection
        let symbol: String
        let label: String
    }

    private static let tabs: [TabItem] = [
        TabItem(id: .feed, symbol: "house.fill", label: "Home"),
        TabItem(id: .profile, symbol: "square.stack.fill", label: "Library"),
        TabItem(id: .search, symbol: "magnifyingglass", label: "Search"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.tabs) { tab in
                tabButton(tab)
            }
        }
        .padding(3)
        .glassEffect(.clear.interactive(), in: Capsule())
        // Sits down into the home-indicator area rather than above it.
        .padding(.bottom, -10)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab bar")
    }

    private func tabButton(_ tab: TabItem) -> some View {
        let isSelected = selection == tab.id
        return Button {
            if reduceMotion {
                selection = tab.id
            } else {
                withAnimation(.snappy(duration: 0.3, extraBounce: 0.05)) { selection = tab.id }
            }
        } label: {
            Image(systemName: tab.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(width: 62, height: 42)
                .background {
                    if isSelected {
                        // Page-coloured so it reads as a lighter inset in
                        // light mode and darker in dark, like the system
                        // bar's selection.
                        Capsule()
                            .fill(Color(.systemBackground).opacity(0.55))
                            .matchedGeometryEffect(id: "selected", in: selector)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
