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
    /// False only between an image landing on a blank row and its reveal
    /// animation finishing; see `ImageRevealModifier`.
    @State private var revealed = true
    /// While any load is in flight the synchronous cache path is off, so the
    /// image can only appear through `load` and the reveal decision is made
    /// exactly once. Without this, any re-render between the pipeline
    /// finishing and `load` resuming (the tone store publishing, a scroll)
    /// inserted the image early with `revealed == true`; `load` then set it
    /// false on a view already on screen and nothing ever animated it back —
    /// rows stuck dim and blurred. A counter, not a flag: a size change
    /// cancels one load and starts another, and the cancelled one's cleanup
    /// must not reopen the window while the new one is still running (the
    /// channel banner hit exactly that).
    @State private var loadsInFlight = 0

    var body: some View {
        GeometryReader { proxy in
            // A memory-cache hit renders in the first frame, before `load`
            // has even started, so scrolling back never shows a placeholder.
            let shown = image ?? (loadsInFlight > 0 ? nil : cachedImage(for: proxy.size)?.image)
            ZStack {
                Rectangle().fill(placeholderStyle)
                if let image = shown {
                    // Fill and crop rather than stretch: the frame's aspect
                    // doesn't always match the image (channel banners are ~6:1
                    // shown at ~3:1, and `hqdefault` is 4:3 with letterbox bars).
                    // The pipeline already downsampled to the display size, so
                    // medium interpolation looks the same and is cheaper while
                    // the reveal animates.
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .imageReveal(revealed)
                        .onAppear {
                            guard !revealed else { return }
                            withAnimation(.imageReveal) { revealed = true }
                        }
                }
            }
            .task(id: loadKey(for: proxy.size)) {
                await load(size: proxy.size)
            }
        }
        .accessibilityHidden(true)
    }

    /// The thumbnail's own average colour when we've seen it before (at any
    /// size), so a blank row and the reveal sit in its tone rather than gray.
    private var placeholderStyle: AnyShapeStyle {
        if let color = ImageToneStore.shared.tone(for: url)?.averageColor {
            return AnyShapeStyle(Color(uiColor: color))
        }
        return AnyShapeStyle(.quaternary)
    }

    private func cachedImage(for size: CGSize) -> ThumbnailImagePipeline.LoadedImage? {
        ThumbnailImagePipeline.shared.cachedImage(
            original: url,
            upgraded: ThumbnailURL.upgraded(url, pixelWidth: Int((size.width * displayScale).rounded(.up))),
            displaySize: size,
            scale: displayScale,
            namespace: namespace)
    }

    private var namespace: String {
        switch networkScope {
        case .selectedInstance: "instance:\(app.instanceGeneration)"
        case .publicInternet: "public"
        }
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
        // Blank right now (nothing in state, nothing in the memory cache) is
        // what earns the reveal when the image lands.
        let wasBlank = image == nil && cachedImage(for: size) == nil
        loadsInFlight += 1
        defer { loadsInFlight -= 1 }
        let client: PolicyHTTPClient? =
            switch networkScope {
            case .selectedInstance: try? app.httpClient
            case .publicInternet: AppModel.publicHTTPClient
            }
        let loaded = await ThumbnailImagePipeline.shared.load(
            original: url,
            upgraded: ThumbnailURL.upgraded(url, pixelWidth: Int((size.width * displayScale).rounded(.up))),
            displaySize: size,
            scale: displayScale,
            client: client,
            namespace: namespace)
        guard !Task.isCancelled, let loaded else { return }
        // A sharper size-only replacement swaps in place; only a blank row
        // animates.
        if wasBlank, image == nil { revealed = false }
        image = loaded.image
    }

}
