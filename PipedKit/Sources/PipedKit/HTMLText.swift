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

        // Numeric decimal entities (&#NNN;)
        while let range = s.range(of: "&#[0-9]+;", options: .regularExpression) {
            let digits = s[range].dropFirst(2).dropLast()
            guard let code = UInt32(digits), let scalar = Unicode.Scalar(code) else { break }
            s.replaceSubrange(range, with: String(scalar))
        }

        // Collapse excessive blank lines
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
