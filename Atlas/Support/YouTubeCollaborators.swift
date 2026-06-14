import Foundation
import PipedKit

@MainActor
enum YouTubeCollaborators {
    private static var cache: [String: [CreatorChannel]] = [:]
    private static var inFlight: [String: Task<[CreatorChannel], Never>] = [:]

    static func channels(for videoID: String) async -> [CreatorChannel] {
        if let cached = cache[videoID] { return cached }
        if let task = inFlight[videoID] { return await task.value }

        let task = Task { await fetch(videoID: videoID) }
        inFlight[videoID] = task
        let channels = await task.value
        cache[videoID] = channels
        inFlight[videoID] = nil
        return channels
    }

    private static func fetch(videoID: String) async -> [CreatorChannel] {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return [] }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8),
              let jsonString = initialDataJSON(in: html),
              let jsonData = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData),
              let items = collaboratorItems(in: root) else {
            return []
        }

        let channels = items.compactMap(parseChannel)
        return deduped(channels).count > 1 ? deduped(channels) : []
    }

    private static func initialDataJSON(in html: String) -> String? {
        for marker in ["var ytInitialData = ", "ytInitialData = "] {
            guard let markerRange = html.range(of: marker),
                  let start = html[markerRange.upperBound...].firstIndex(of: "{") else {
                continue
            }

            var index = start
            var depth = 0
            var inString = false
            var escaping = false

            while index < html.endIndex {
                let char = html[index]
                if inString {
                    if escaping {
                        escaping = false
                    } else if char == "\\" {
                        escaping = true
                    } else if char == "\"" {
                        inString = false
                    }
                } else if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(html[start...index])
                    }
                }
                index = html.index(after: index)
            }
        }
        return nil
    }

    private static func collaboratorItems(in value: Any) -> [[String: Any]]? {
        if let dictionary = value as? [String: Any] {
            if isCollaboratorsDialog(dictionary),
               let items = dictionary.value(at: ["customContent", "listViewModel", "listItems"]) as? [[String: Any]] {
                return items
            }

            for nested in dictionary.values {
                if let found = collaboratorItems(in: nested) { return found }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = collaboratorItems(in: nested) { return found }
            }
        }
        return nil
    }

    private static func isCollaboratorsDialog(_ dictionary: [String: Any]) -> Bool {
        let headline = dictionary.string(at: ["header", "dialogHeaderViewModel", "headline", "content"])
            ?? dictionary.string(at: ["header", "dialogHeaderViewModel", "headline", "simpleText"])
        return headline == "Collaborators"
    }

    private static func parseChannel(_ item: [String: Any]) -> CreatorChannel? {
        let model = item["listItemViewModel"] as? [String: Any] ?? item
        guard let name = text(in: model["title"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }

        let channelID = findChannelID(in: model)
        return CreatorChannel(name: name,
                              channelID: channelID,
                              avatarURL: normalizeURL(findSourceURL(in: model)),
                              subtitle: subtitle(in: model, name: name),
                              isVerified: false)
    }

    private static func text(in value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let dictionary = value as? [String: Any] {
            if let content = dictionary["content"] as? String { return content }
            if let simpleText = dictionary["simpleText"] as? String { return simpleText }
            if let runs = dictionary["runs"] as? [[String: Any]] {
                let joined = runs.compactMap { $0["text"] as? String }.joined()
                return joined.isEmpty ? nil : joined
            }
        }
        return nil
    }

    private static func findSourceURL(in value: Any?) -> String? {
        guard let value else { return nil }
        if let dictionary = value as? [String: Any] {
            if let sources = dictionary["sources"] as? [[String: Any]] {
                let sourceURL = sources
                    .compactMap { source -> (url: String, width: Int)? in
                        guard let url = source["url"] as? String else { return nil }
                        return (url, source["width"] as? Int ?? 0)
                    }
                    .max { $0.width < $1.width }?
                    .url
                if let sourceURL {
                    return sourceURL
                }
            }
            for nested in dictionary.values {
                if let found = findSourceURL(in: nested) { return found }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = findSourceURL(in: nested) { return found }
            }
        }
        return nil
    }

    private static func findChannelID(in value: Any?) -> String? {
        guard let value else { return nil }
        if let dictionary = value as? [String: Any] {
            if let endpoint = dictionary["browseEndpoint"] as? [String: Any],
               let id = endpoint["browseId"] as? String,
               id.hasPrefix("UC") {
                return id
            }
            if let metadata = dictionary["webCommandMetadata"] as? [String: Any],
               let id = PipedID.channel(fromURL: metadata["url"] as? String) {
                return id
            }
            for nested in dictionary.values {
                if let found = findChannelID(in: nested) { return found }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = findChannelID(in: nested) { return found }
            }
        }
        return nil
    }

    private static func subtitle(in value: [String: Any], name: String) -> String? {
        guard var label = findAccessibilityLabel(in: value) else { return nil }
        if label.hasSuffix(". Go to channel") {
            label.removeLast(". Go to channel".count)
        }
        let prefix = "\(name) - "
        guard label.hasPrefix(prefix) else { return nil }
        let subtitle = label.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return subtitle.isEmpty ? nil : subtitle
    }

    private static func findAccessibilityLabel(in value: Any?) -> String? {
        guard let value else { return nil }
        if let dictionary = value as? [String: Any] {
            if let context = dictionary["accessibilityContext"] as? [String: Any],
               let label = context["label"] as? String {
                return label
            }
            for nested in dictionary.values {
                if let found = findAccessibilityLabel(in: nested) { return found }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = findAccessibilityLabel(in: nested) { return found }
            }
        }
        return nil
    }

    private static func normalizeURL(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("//") { return "https:\(value)" }
        return value
    }

    private static func deduped(_ channels: [CreatorChannel]) -> [CreatorChannel] {
        var seen = Set<String>()
        var output: [CreatorChannel] = []
        for channel in channels {
            let key = channel.channelID ?? channel.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(channel)
        }
        return output
    }
}

private extension Dictionary where Key == String, Value == Any {
    func value(at path: [String]) -> Any? {
        var current: Any = self
        for segment in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[segment] else {
                return nil
            }
            current = next
        }
        return current
    }

    func string(at path: [String]) -> String? {
        value(at: path) as? String
    }
}
