import Foundation

public enum PipedError: Error, LocalizedError, Sendable {
    case badURL
    case http(Int)
    case upstream(String, statusCode: Int? = nil)
    case noPlayableStream
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .badURL: "Invalid request URL."
        case .http(let code): "Server returned HTTP \(code)."
        case .upstream(let message, _): message
        case .noPlayableStream: "This instance couldn't load a playable stream. Try another instance."
        case .decoding(let message): "Couldn't read the response: \(message)"
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
                return .upstream("This live event has not started yet. \(quoted)", statusCode: statusCode)
            }
            return .upstream("This live event has not started yet.", statusCode: statusCode)
        }

        if rawMessage.contains("SignInConfirmNotBotException") {
            return .upstream("This instance was blocked by YouTube. Try another instance.", statusCode: statusCode)
        }

        // Surface any other upstream message (age restriction, geo blocks, …)
        // instead of collapsing it into a bare status code.
        return .upstream(rawMessage, statusCode: statusCode)
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
