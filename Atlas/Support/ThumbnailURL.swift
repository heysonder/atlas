import Foundation

enum ThumbnailURL {
    /// Widths YouTube serves channel banners at (`=w2560-fcrop64=…`); the crop
    /// parameter keeps the same ~6:1 band at every width.
    private static let bannerWidths = [1060, 1138, 1707, 2120, 2276, 2560]
    /// Square sizes YouTube serves avatars at (`=s160-c-k-…`).
    private static let avatarSizes = [88, 176, 240, 360, 480, 800]

    /// Best URL for the pixel width a view is about to display:
    /// - Google-hosted banners and avatars (`yt3.googleusercontent.com`,
    ///   `yt3.ggpht.com`, directly or through a Piped proxy) get their size
    ///   parameter bumped to the smallest served size that covers the view,
    ///   so a phone doesn't pull a 2560px banner and an iPad or a 64pt @3x
    ///   avatar isn't upscaled from a 160px file.
    /// - Video thumbnails go through `upgraded(_:)` to `maxresdefault`.
    /// Callers pass the result as the pipeline's `upgraded` candidate; the
    /// original stays the fallback if the rewritten file doesn't resolve.
    static func upgraded(_ urlString: String?, pixelWidth: Int?) -> String? {
        guard let urlString, let pixelWidth, pixelWidth > 0, isGoogleHosted(urlString) else {
            return upgraded(urlString)
        }
        if let sized = replacingSizeParameter(
            in: urlString, pattern: #"=w(\d+)-fcrop64="#, prefix: "=w", suffix: "-fcrop64=",
            sizes: bannerWidths, needed: pixelWidth)
        {
            return sized
        }
        if let sized = replacingSizeParameter(
            in: urlString, pattern: #"=s(\d+)-"#, prefix: "=s", suffix: "-",
            sizes: avatarSizes, needed: pixelWidth)
        {
            return sized
        }
        return urlString
    }

    private static func isGoogleHosted(_ urlString: String) -> Bool {
        urlString.contains("googleusercontent.com") || urlString.contains("ggpht.com")
    }

    private static func replacingSizeParameter(
        in urlString: String, pattern: String, prefix: String, suffix: String,
        sizes: [Int], needed: Int
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
            let range = Range(match.range, in: urlString)
        else { return nil }
        let size = sizes.first { $0 >= needed } ?? sizes.last!
        return urlString.replacingCharacters(in: range, with: "\(prefix)\(size)\(suffix)")
    }

    /// Rewrites a Piped/YouTube thumbnail URL's variant to `maxresdefault`,
    /// dropping the variant-specific signature query so the new file resolves.
    /// Returns the input unchanged for already-HD or unrecognized URLs.
    static func upgraded(_ urlString: String?) -> String? {
        guard let urlString,
            var components = URLComponents(string: urlString)
        else {
            return urlString
        }
        var pathParts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard let lastPathPart = pathParts.last, lastPathPart.contains(".") else {
            return urlString
        }

        let fileExtension = lastPathPart.hasSuffix(".webp") ? "webp" : "jpg"
        let variant = lastPathPart.dropLast(fileExtension.count + 1)
        let lowResolutionVariants: Set<Substring> = [
            "default",
            "mqdefault",
            "hqdefault",
            "sddefault",
        ]
        guard lowResolutionVariants.contains(variant) else { return urlString }

        pathParts[pathParts.count - 1] = Substring("maxresdefault.\(fileExtension)")
        components.path = pathParts.joined(separator: "/")
        let host = components.queryItems?.first { $0.name == "host" }?.value ?? "i.ytimg.com"
        components.queryItems = [URLQueryItem(name: "host", value: host)]
        return components.string
    }
}
