import Foundation

enum ThumbnailURL {
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
