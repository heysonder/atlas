import SwiftUI

/// Shared 120×68 thumbnail used by library list rows and iPad cards.
struct LibraryVideoThumbnail: View {
    let url: String?
    var durationSeconds: Int? = nil
    var networkScope: RemoteResourceScope = .publicInternet

    private var durationText: String {
        Format.duration(durationSeconds)
    }

    var body: some View {
        // A fixed corner (not concentric with the surrounding card) because the
        // duration chip nests into it, and only a rounded rectangle can be a
        // container shape.
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack(alignment: .bottomTrailing) {
            Thumbnail(url: url, networkScope: networkScope)
                .aspectRatio(16 / 9, contentMode: .fill)
                .frame(width: 120, height: 68)
                .clipShape(shape)
                .imageEdge(shape, url: url)
            if !durationText.isEmpty {
                // A pill on three corners; the bottom-trailing one nests
                // concentrically into the thumbnail's corner instead.
                ThumbnailChip(
                    shape: ConcentricRectangle(
                        topLeadingCorner: .fixed(12), topTrailingCorner: .fixed(12),
                        bottomLeadingCorner: .fixed(12),
                        bottomTrailingCorner: .concentric(minimum: .fixed(3))),
                    compact: true
                ) {
                    Text(durationText)
                }
                .padding(4)
            }
        }
        .containerShape(shape)
    }
}
