import Foundation

/// Converts the HTML that Piped returns in description fields into clean plain text.
/// Piped descriptions wrap links as `<a href="URL">URL</a>` and use `<br>` for breaks.
public enum HTMLText {
    public static func plain(_ html: String) -> String {
        var s = html

        // Line breaks
        for tag in ["<br>", "<br/>", "<br />"] {
            s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)

        // Strip every remaining tag (the visible link text — usually the URL — is kept).
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Named entities
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&#39;": "'", "&#x27;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in named { s = s.replacingOccurrences(of: k, with: v) }

        s = decodeNumericEntities(in: s)

        // Collapse excessive blank lines
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNumericEntities(in text: String) -> String {
        let pattern = #"&#(?:[0-9]+|x[0-9A-Fa-f]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var output = ""
        var cursor = text.startIndex
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            output += text[cursor..<matchRange.lowerBound]
            let entity = String(text[matchRange])
            let digits: Substring
            let radix: Int
            if entity.lowercased().hasPrefix("&#x") {
                digits = entity.dropFirst(3).dropLast()
                radix = 16
            } else {
                digits = entity.dropFirst(2).dropLast()
                radix = 10
            }
            if let code = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(code) {
                output += String(scalar)
            } else {
                output += entity
            }
            cursor = matchRange.upperBound
        }

        output += text[cursor...]
        return output
    }
}
