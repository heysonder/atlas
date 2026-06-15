import Foundation

public enum PipedError: Error, LocalizedError {
    case badURL
    case http(Int)
    case upstream(String)
    case noPlayableStream
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .badURL: "Invalid request URL."
        case .http(let code): "Server returned HTTP \(code)."
        case .upstream(let message): message
        case .noPlayableStream: "This instance couldn't load a playable stream. Try another instance."
        case .decoding(let m): "Couldn't read the response: \(m)"
        }
    }

    static func fromHTTPStatus(_ statusCode: Int, data: Data) -> PipedError {
        guard let body = try? JSONDecoder().decode(PipedServerError.self, from: data),
              let rawMessage = body.error?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawMessage.isEmpty
        else {
            return .http(statusCode)
        }

        if rawMessage.contains("LIVE_STREAM_OFFLINE") {
            if let quoted = Self.quotedMessage(in: rawMessage) {
                return .upstream("This live event has not started yet. \(quoted)")
            }
            return .upstream("This live event has not started yet.")
        }

        if rawMessage.contains("SignInConfirmNotBotException") {
            return .upstream("This instance was blocked by YouTube. Try another instance.")
        }

        return .http(statusCode)
    }

    private static func quotedMessage(in message: String) -> String? {
        guard let first = message.firstIndex(of: "\"") else { return nil }
        let rest = message[message.index(after: first)...]
        guard let last = rest.firstIndex(of: "\"") else { return nil }
        let quoted = rest[..<last].trimmingCharacters(in: .whitespacesAndNewlines)
        return quoted.isEmpty ? nil : quoted
    }
}

private struct PipedServerError: Decodable {
    let error: String?
}

/// A thin async client for one Piped instance.
/// `baseURL` is an instance's api_url, e.g. https://api.piped.private.coffee
public struct PipedClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public init?(instanceString: String, session: URLSession = .shared) {
        guard let url = URL(string: instanceString) else { return nil }
        self.init(baseURL: url, session: session)
    }

    // MARK: Endpoints

    /// `filter` is a Piped search filter: "videos", "channels", "playlists", "all".
    public func search(_ query: String, filter: String = "videos") async throws -> [StreamItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let res: SearchResponse = try await get("search", query: [
            "q": trimmed, "filter": filter
        ])
        return res.items ?? []
    }

    /// Autocomplete suggestions for a partial query.
    public func suggestions(_ query: String) async throws -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let result: [String] = try await get("suggestions", query: ["query": trimmed])
        return result
    }

    public func streams(videoID: String) async throws -> VideoDetail {
        try await get("streams/\(videoID)")
    }

    public func channel(id: String) async throws -> Channel {
        try await get("channel/\(id)")
    }

    /// Continues paging a channel's uploads with the `nextpage` token returned by
    /// `/channel/:channelId` or a previous channel next-page response.
    public func channelNextPage(id: String, nextpage: String) async throws -> Channel {
        try await get("nextpage/channel/\(id)", query: ["nextpage": nextpage])
    }

    /// First page of a video's comments. `CommentsPage.disabled` is true when the
    /// uploader has turned comments off.
    public func comments(videoID: String) async throws -> CommentsPage {
        try await get("comments/\(videoID)")
    }

    /// Continues paging comments (or replies) with a `nextpage` / `repliesPage`
    /// token returned by a previous `comments(videoID:)` call.
    public func commentsNextPage(videoID: String, nextpage: String) async throws -> CommentsPage {
        try await get("nextpage/comments/\(videoID)", query: ["nextpage": nextpage])
    }

    /// Crowdsourced SponsorBlock skip segments for a video, proxied by the
    /// instance. `categories` are SponsorBlock category ids (see `SponsorCategory`).
    /// Returns an empty array when none are requested or the video has no data.
    public func sponsorSegments(
        videoID: String, categories: [String]
    ) async throws -> [SponsorSegment] {
        guard !categories.isEmpty else { return [] }
        // Piped expects the categories as a JSON-array string, e.g. ["sponsor","intro"].
        let json = "[" + categories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let res: SponsorSegmentsResponse = try await get(
            "sponsors/\(videoID)", query: ["category": json])
        return res.segments ?? []
    }

    /// Aggregated, reverse-chronological feed for the given channel ids.
    public func feed(channelIDs: [String]) async throws -> [StreamItem] {
        guard !channelIDs.isEmpty else { return [] }
        let items: [StreamItem] = try await get("feed/unauthenticated", query: [
            "channels": channelIDs.joined(separator: ",")
        ])
        return items
    }

    /// Public trending videos for a region. Useful as a cold-start feed before
    /// the user has local subscriptions or enough watch/search history.
    public func trending(region: String = "US") async throws -> [StreamItem] {
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "US" : trimmed.uppercased()
        let items: [StreamItem] = try await get("trending", query: ["region": resolved])
        return items
    }

    // MARK: Static instance directory (separate host)

    public static func fetchInstances(
        session: URLSession = .shared
    ) async throws -> [PipedInstance] {
        let url = URL(string: "https://piped-instances.kavin.rocks/")!
        let (data, response) = try await session.data(from: url)
        try Self.validate(response, data: data)
        do {
            return try JSONDecoder().decode([PipedInstance].self, from: data)
        } catch {
            throw PipedError.decoding(String(describing: error))
        }
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            comps?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps?.url else { throw PipedError.badURL }

        let (data, response) = try await session.data(from: url)
        try Self.validate(response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PipedError.decoding(String(describing: error))
        }
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw PipedError.fromHTTPStatus(http.statusCode, data: data)
        }
    }
}
