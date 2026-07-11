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
        ZStack(alignment: .bottomTrailing) {
            Thumbnail(url: url, networkScope: networkScope)
                .aspectRatio(16 / 9, contentMode: .fill)
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if !durationText.isEmpty {
                Text(durationText)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(5)
            }
        }
    }
}
