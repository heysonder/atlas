import SwiftUI
import UIKit

/// Shared sizing for library grids (History, Downloads, Playlists, Search
/// channels). One adaptive track tiles as many columns as fit the width, so the
/// same call yields 1 column on a phone and 2–3 on iPad — matching how the feed
/// (`GroupedVideoList`) already scales.
enum LibraryGrid {
    static let spacing: CGFloat = 12
    /// Card outline shared by `libraryCard()`'s fill, hit area and container shape.
    static let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    /// Cards drop a column below `minCardWidth`. Tuned so the app's horizontal
    /// thumbnail+text rows stay legible: ~1 column on a phone, 2–3 on iPad.
    static func columns(minCardWidth: CGFloat = 360) -> [GridItem] {
        [GridItem(.adaptive(minimum: minCardWidth), spacing: spacing, alignment: .top)]
    }

    /// The narrowest container in which the card grid is worth using: two
    /// minimum-width cards side by side. Below that a single column of cards
    /// is just a list with wasted padding.
    static func minimumGridWidth(minCardWidth: CGFloat = 360, outerPadding: CGFloat = 16) -> CGFloat {
        minCardWidth * 2 + spacing + outerPadding * 2
    }
}

/// Picks the card grid when two cards fit the available width and the plain
/// list otherwise — decided by the layout system (`ViewThatFits`) from the
/// space actually offered, so a resized iPad window, Stage Manager, Slide
/// Over and an iPhone all fall out of the same rule with no size-class or
/// screen-width branches.
struct LibraryLayout<Grid: View, List: View>: View {
    var minCardWidth: CGFloat = 360
    @ViewBuilder var grid: () -> Grid
    @ViewBuilder var list: () -> List

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid()
                .frame(minWidth: LibraryGrid.minimumGridWidth(minCardWidth: minCardWidth))
            list()
        }
    }
}

/// A multi-column grid for library surfaces on iPad. Callers keep a `List` for
/// compact width (so iPhone retains swipe-to-delete) and use this only at
/// regular width, where the extra columns earn their keep.
struct AdaptiveGrid<Header: View, Content: View>: View {
    var minCardWidth: CGFloat = 360
    /// Full-width content above the grid (a shelf, a section title).
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    init(
        minCardWidth: CGFloat = 360,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.minCardWidth = minCardWidth
        self.header = header
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header()
                LazyVGrid(
                    columns: LibraryGrid.columns(minCardWidth: minCardWidth),
                    spacing: LibraryGrid.spacing
                ) {
                    content()
                }
            }
            .padding()
        }
    }
}

extension AdaptiveGrid where Header == EmptyView {
    init(minCardWidth: CGFloat = 360, @ViewBuilder content: @escaping () -> Content) {
        self.init(minCardWidth: minCardWidth, header: { EmptyView() }, content: content)
    }
}

extension View {
    /// Frames a row as a tappable tile inside `AdaptiveGrid`: the same row view
    /// the compact `List` renders, wrapped in padding + a rounded fill that reads
    /// against the default background. Keeps iPhone and iPad cards identical in
    /// content, differing only in how they're laid out.
    func libraryCard() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: LibraryGrid.cardShape)
            .contentShape(LibraryGrid.cardShape)
            // Lets nested thumbnails pick a corner concentric with the card.
            .containerShape(LibraryGrid.cardShape)
    }
}
