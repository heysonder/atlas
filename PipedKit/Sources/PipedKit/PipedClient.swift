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

        // Surface any other upstream message (age restriction, geo blocks, …)
        // instead of collapsing it into a bare status code.
        return .upstream(rawMessage)
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
    /// Generous because /streams extraction alone can take several seconds on
    /// self-hosted instances.
    private static let requestTimeout: TimeInterval = 15
    private static let resourceTimeout: TimeInterval = 45
    private static let boundedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration)
    }()

    public init(baseURL: URL) {
        self.init(baseURL: baseURL, session: Self.boundedSession)
    }

    public init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
    }

    public init?(instanceString: String) {
        self.init(instanceString: instanceString, session: Self.boundedSession)
    }

    public init?(instanceString: String, session: URLSession) {
        guard let url = URL(string: instanceString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        self.init(baseURL: url, session: session)
    }

    // MARK: Endpoints

    /// `filter` is a Piped search filter: "videos", "channels", "playlists", "all".
    /// Returns just the items; use `searchPage` when you also need the `nextpage`
    /// token to paginate.
    public func search(_ query: String, filter: String = "videos") async throws -> [StreamItem] {
        try await searchPage(query, filter: filter).items ?? []
    }

    /// First page of search results, keeping the `nextpage` token so callers can
    /// continue with `searchNextPage`.
    public func searchPage(_ query: String, filter: String = "videos") async throws -> SearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchResponse(items: [], nextpage: nil, suggestion: nil, corrected: nil)
        }
        return try await get("search", query: ["q": trimmed, "filter": filter])
    }

    /// Continues a search with the `nextpage` token from a previous `searchPage`
    /// (or `searchNextPage`). Piped's `/nextpage/search` still wants the original
    /// `q` + `filter` alongside the token.
    public func searchNextPage(_ query: String, filter: String = "videos",
                               nextpage: String) async throws -> SearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchResponse(items: [], nextpage: nil, suggestion: nil, corrected: nil)
        }
        return try await get("nextpage/search", query: [
            "nextpage": nextpage, "q": trimmed, "filter": filter
        ])
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

    public func av1HLSMasterURL(videoID: String) -> URL {
        baseURL
            .appendingPathComponent("hls")
            .appendingPathComponent("av1")
            .appendingPathComponent(videoID)
            .appendingPathComponent("master.m3u8")
    }

    public func channel(id: String) async throws -> Channel {
        try await get("channel/\(id)")
    }

    /// Continues paging a channel's uploads with the `nextpage` token returned by
    /// `/channel/:channelId` or a previous channel next-page response.
    public func channelNextPage(id: String, nextpage: String) async throws -> Channel {
        try await get("nextpage/channel/\(id)", query: ["nextpage": nextpage])
    }

    /// Loads one of the channel tabs advertised by `/channel/:channelId`, such as
    /// the Shorts tab. Pass the tab's raw `data` value back to Piped unchanged.
    public func channelTab(data: String, nextpage: String? = nil) async throws -> ChannelTabPage {
        var query = ["data": data]
        if let nextpage {
            query["nextpage"] = nextpage
        }
        return try await get("channels/tabs", query: query)
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
        let json = try Self.sponsorCategoriesJSON(categories)
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

    /// Piped expects the categories as a JSON-array string, e.g. ["sponsor","intro"].
    /// Built with JSONEncoder so quotes/backslashes in a category can't break the array.
    static func sponsorCategoriesJSON(_ categories: [String]) throws -> String {
        let data = try JSONEncoder().encode(categories)
        guard let json = String(data: data, encoding: .utf8) else {
            throw PipedError.badURL
        }
        return json
    }

    // MARK: Static instance directory (separate host)

    public static func fetchInstances() async throws -> [PipedInstance] {
        try await fetchInstances(session: Self.boundedSession)
    }

    public static func fetchInstances(session: URLSession) async throws -> [PipedInstance] {
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
        let url = try Self.url(baseURL: baseURL, path: path, query: query)

        let (data, response) = try await session.data(from: url)
        try Self.validate(response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PipedError.decoding(String(describing: error))
        }
    }

    static func url(baseURL: URL, path: String, query: [String: String] = [:]) throws -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            comps?.percentEncodedQueryItems = try query
                .sorted { $0.key < $1.key }
                .map {
                    URLQueryItem(
                        name: try percentEncodeQueryComponent($0.key),
                        value: try percentEncodeQueryComponent($0.value))
                }
        }
        guard let url = comps?.url else { throw PipedError.badURL }
        return url
    }

    private static func percentEncodeQueryComponent(_ value: String) throws -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#[]")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            // Never hand percentEncodedQueryItems a raw string — it traps on
            // characters that aren't already percent-encoded.
            throw PipedError.badURL
        }
        return encoded
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw PipedError.fromHTTPStatus(http.statusCode, data: data)
        }
    }
}
