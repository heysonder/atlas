import SwiftUI

/// Network thumbnail with a neutral placeholder.
///
/// Piped serves channel/related-stream items with the low-res `hqdefault`
/// (480×360) variant, while feed/search items come through as `maxresdefault`
/// (1280×720). We upgrade the low-res variants to `maxresdefault`, then fall
/// back to the original URL if that frame doesn't exist (some older videos).
struct Thumbnail: View {
    let url: String?
    @State private var triedUpgrade = false

    var body: some View {
        let hd = Self.upgraded(url)
        let target = triedUpgrade ? url : (hd ?? url)
        AsyncImage(url: target.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().interpolation(.high)
            case .failure:
                // maxresdefault probably 404'd — retry once with the original variant.
                if !triedUpgrade, hd != nil, hd != url {
                    Rectangle().fill(.quaternary).onAppear { triedUpgrade = true }
                } else {
                    Rectangle().fill(.quaternary)
                }
            default:
                Rectangle().fill(.quaternary)
            }
        }
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
