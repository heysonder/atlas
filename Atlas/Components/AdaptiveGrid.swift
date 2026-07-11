import SwiftUI
import UIKit

/// Shared sizing for library grids (History, Downloads, Playlists, Search
/// channels). One adaptive track tiles as many columns as fit the width, so the
/// same call yields 1 column on a phone and 2–3 on iPad — matching how the feed
/// (`GroupedVideoList`) already scales.
enum LibraryGrid {
    static let spacing: CGFloat = 12

    /// Cards drop a column below `minCardWidth`. Tuned so the app's horizontal
    /// thumbnail+text rows stay legible: ~1 column on a phone, 2–3 on iPad.
    static func columns(minCardWidth: CGFloat = 360) -> [GridItem] {
        [GridItem(.adaptive(minimum: minCardWidth), spacing: spacing, alignment: .top)]
    }
}

/// A multi-column grid for library surfaces on iPad. Callers keep a `List` for
/// compact width (so iPhone retains swipe-to-delete) and use this only at
/// regular width, where the extra columns earn their keep.
struct AdaptiveGrid<Content: View>: View {
    var minCardWidth: CGFloat = 360
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: LibraryGrid.columns(minCardWidth: minCardWidth),
                spacing: LibraryGrid.spacing
            ) {
                content()
            }
            .padding()
        }
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
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
