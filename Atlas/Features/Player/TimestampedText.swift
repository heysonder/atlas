import SwiftUI
import PipedKit

/// Renders player-adjacent text with tappable video timestamps such as `0:42`
/// and `1:02:03`.
struct TimestampedText: View {
    let text: String
    let timestamps: [CommentTimestamp]
    let onTimestampTap: (Int) -> Void

    private static let urlScheme = "atlas-player-timestamp"

    init(
        text: String,
        timestamps: [CommentTimestamp]? = nil,
        onTimestampTap: @escaping (Int) -> Void
    ) {
        self.text = text
        self.timestamps = timestamps ?? CommentTimestamp.extract(from: text)
        self.onTimestampTap = onTimestampTap
    }

    var body: some View {
        Text(attributedText)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == Self.urlScheme,
                      let secondsText = URLComponents(
                        url: url,
                        resolvingAgainstBaseURL: false)?.host,
                      let seconds = Int(secondsText) else {
                    return .systemAction
                }
                onTimestampTap(seconds)
                return .handled
            })
    }

    private var attributedText: AttributedString {
        guard !timestamps.isEmpty else { return AttributedString(text) }

        var output = AttributedString()
        var cursor = text.startIndex

        for timestamp in timestamps {
            guard let range = text.range(
                of: timestamp.label,
                range: cursor..<text.endIndex
            ) else { continue }

            if cursor < range.lowerBound {
                output += AttributedString(String(text[cursor..<range.lowerBound]))
            }

            var linkedTimestamp = AttributedString(String(text[range]))
            linkedTimestamp.link = URL(string: "\(Self.urlScheme)://\(timestamp.seconds)")
            linkedTimestamp.foregroundColor = .accentColor
            output += linkedTimestamp
            cursor = range.upperBound
        }

        if cursor < text.endIndex {
            output += AttributedString(String(text[cursor..<text.endIndex]))
        }

        return output
    }
}
