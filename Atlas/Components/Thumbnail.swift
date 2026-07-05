import SwiftUI
import UIKit
import ImageIO

/// Network thumbnail with a neutral placeholder.
///
/// Piped serves channel/related-stream items with the low-res `hqdefault`
/// (480×360) variant, while feed/search items come through as `maxresdefault`
/// (1280×720). We upgrade the low-res variants to `maxresdefault`, then fall
/// back to the original URL if that frame doesn't exist (some older videos).
struct Thumbnail: View {
    let url: String?
    @Environment(\.displayScale) private var displayScale
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
    }

    private func loadKey(for size: CGSize) -> String {
        let width = Int((size.width * displayScale).rounded(.up))
        let height = Int((size.height * displayScale).rounded(.up))
        return "\(url ?? "")|\(width)x\(height)"
    }

    private func load(size: CGSize) async {
        // Only clear when the video identity changed; on a pure size change the
        // old image stays up until the sharper replacement arrives.
        if imageURL != url {
            image = nil
            imageURL = url
        }
        let loaded = await ThumbnailImagePipeline.shared.image(
            original: url,
            upgraded: Self.upgraded(url),
            displaySize: size,
            scale: displayScale)
        guard !Task.isCancelled, let loaded else { return }
        image = loaded
    }

    /// Rewrites a Piped/YouTube thumbnail URL's variant to `maxresdefault`,
    /// dropping the variant-specific signature query so the new file resolves.
    /// Returns the input unchanged for already-HD or unrecognised URLs.
    static func upgraded(_ s: String?) -> String? {
        guard let s, var comps = URLComponents(string: s) else { return s }
        var parts = comps.path.split(separator: "/", omittingEmptySubsequences: false)
        guard let last = parts.last, last.contains(".") else { return s }
        let ext = last.hasSuffix(".webp") ? "webp" : "jpg"
        let variant = last.dropLast(ext.count + 1)
        let lowRes: Set<Substring> = ["default", "mqdefault", "hqdefault", "sddefault"]
        guard lowRes.contains(variant) else { return s }
        parts[parts.count - 1] = Substring("maxresdefault.\(ext)")
        comps.path = parts.joined(separator: "/")
        let host = comps.queryItems?.first { $0.name == "host" }?.value ?? "i.ytimg.com"
        comps.queryItems = [URLQueryItem(name: "host", value: host)]
        return comps.string
    }
}

private actor ThumbnailImagePipeline {
    static let shared = ThumbnailImagePipeline()

    private struct CacheKey: Hashable {
        let url: String
        let maxPixelDimension: Int
    }

    private var cache: [CacheKey: UIImage] = [:]
    private var order: [CacheKey] = []
    private var totalCost = 0
    private let session: URLSession = .shared
    /// Evict by decoded byte cost (width × height × 4), not entry count — a few
    /// large decodes cost as much as dozens of list thumbnails.
    private let costLimit = 64 * 1024 * 1024

    func image(original: String?, upgraded: String?, displaySize: CGSize, scale: CGFloat) async -> UIImage? {
        let maxPixelDimension = Self.maxPixelDimension(for: displaySize, scale: scale)
        let candidates = Self.candidateURLs(original: original, upgraded: upgraded)
        for url in candidates {
            let key = CacheKey(url: url.absoluteString, maxPixelDimension: maxPixelDimension)
            if let cached = cache[key] { return cached }
            guard let image = await fetchAndDecode(url: url, maxPixelDimension: maxPixelDimension)
            else { continue }
            insert(image, for: key)
            return image
        }
        return nil
    }

    private func fetchAndDecode(url: URL, maxPixelDimension: Int) async -> UIImage? {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await session.data(for: request),
              Self.isSuccessful(response) else { return nil }
        return await Task.detached(priority: .utility) {
            Self.downsample(data: data, maxPixelDimension: maxPixelDimension)
        }.value
    }

    private func insert(_ image: UIImage, for key: CacheKey) {
        guard cache[key] == nil else { return }
        cache[key] = image
        order.append(key)
        totalCost += Self.cost(of: image)
        while totalCost > costLimit, !order.isEmpty {
            if let evicted = cache.removeValue(forKey: order.removeFirst()) {
                totalCost -= Self.cost(of: evicted)
            }
        }
    }

    /// Estimated decoded footprint: 4 bytes per pixel.
    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else {
            return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        }
        return cgImage.width * cgImage.height * 4
    }

    private static func maxPixelDimension(for displaySize: CGSize, scale: CGFloat) -> Int {
        let measured = max(displaySize.width, displaySize.height) * max(scale, 1)
        guard measured.isFinite, measured > 0 else { return 768 }
        let bucket = Int((measured / 64).rounded(.up)) * 64
        return min(max(bucket, 128), 1_536)
    }

    private static func candidateURLs(original: String?, upgraded: String?) -> [URL] {
        var seen = Set<String>()
        return [upgraded, original].compactMap { raw in
            guard let raw, !seen.contains(raw), let url = URL(string: raw) else { return nil }
            seen.insert(raw)
            return url
        }
    }

    private static func isSuccessful(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(http.statusCode)
    }

    private static func downsample(data: Data, maxPixelDimension: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
