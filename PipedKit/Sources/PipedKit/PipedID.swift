import Foundation

public enum PipedID {
    public static func video(fromWatchURL url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        // Handles both the relative "/watch?v=ID" that Piped normally returns
        // and absolute "https://youtube.com/watch?v=ID" forms; URLComponents
        // parses the query of either. Unparseable junk yields nil.
        guard let components = URLComponents(string: url) else { return nil }
        return components.queryItems?.first(where: { $0.name == "v" })?.value
    }

    public static func channel(fromURL url: String?) -> String? {
        guard let url, let range = url.range(of: "/channel/") else { return nil }
        let tail = url[range.upperBound...]
        return tail.split(separator: "/").first.map(String.init)
    }
}
