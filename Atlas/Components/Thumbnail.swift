import PipedKit
import SwiftUI
import UIKit

/// Network thumbnail with a neutral placeholder.
///
/// Piped serves channel/related-stream items with the low-res `hqdefault`
/// (480×360) variant, while feed/search items come through as `maxresdefault`
/// (1280×720). We upgrade the low-res variants to `maxresdefault`, then fall
/// back to the original URL if that frame doesn't exist (some older videos).
struct Thumbnail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale

    let url: String?
    var networkScope: RemoteResourceScope = .publicInternet

    @State private var image: UIImage?
    /// The URL `image` was loaded for, so size-only reloads keep showing the
    /// current image instead of flashing the gray placeholder.
    @State private var imageURL: String?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .task(id: loadKey(for: proxy.size)) {
                await load(size: proxy.size)
            }
        }
        .accessibilityHidden(true)
    }

    private func loadKey(for size: CGSize) -> String {
        let width = Int((size.width * displayScale).rounded(.up))
        let height = Int((size.height * displayScale).rounded(.up))
        let generation = networkScope == .selectedInstance ? app.instanceGeneration : 0
        return "\(generation)|\(url ?? "")|\(width)x\(height)"
    }

    private func load(size: CGSize) async {
        // Only clear when the video identity changed; on a pure size change the
        // old image stays up until the sharper replacement arrives.
        if imageURL != url {
            image = nil
            imageURL = url
        }
        let client: PolicyHTTPClient?
        let namespace: String
        switch networkScope {
        case .selectedInstance:
            client = try? app.httpClient
            namespace = "instance:\(app.instanceGeneration)"
        case .publicInternet:
            client = AppModel.publicHTTPClient
            namespace = "public"
        }
        let loaded = await ThumbnailImagePipeline.shared.image(
            original: url,
            upgraded: ThumbnailURL.upgraded(url),
            displaySize: size,
            scale: displayScale,
            client: client,
            namespace: namespace)
        guard !Task.isCancelled, let loaded else { return }
        image = loaded
    }

}
