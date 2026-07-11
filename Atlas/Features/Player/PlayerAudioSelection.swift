import AVFoundation

enum PlayerAudioSelection {
    @MainActor
    static func selectPreferredAudio(
        for item: AVPlayerItem,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
            let option = preferredOption(in: group.options, preferredLanguages: preferredLanguages)
        else {
            return
        }
        item.select(option, in: group)
    }

    private static func preferredOption(
        in options: [AVMediaSelectionOption],
        preferredLanguages: [String]
    ) -> AVMediaSelectionOption? {
        let scored =
            options
            .map { option in (option, score(option, preferredLanguages: preferredLanguages)) }
            .filter { $0.1 > 0 }
        return scored.max { $0.1 < $1.1 }?.0
    }

    private static func score(
        _ option: AVMediaSelectionOption,
        preferredLanguages: [String]
    ) -> Int {
        let hints = audioLanguageHints(for: option)
        var languageScore = 0
        for (index, language) in preferredLanguagesWithEnglishFallback(preferredLanguages).enumerated() {
            let weight = max(0, 1_000 - index * 25)
            if hints.contains(language) {
                languageScore = max(languageScore, weight)
            } else if hints.contains(where: { hint in
                hint.hasPrefix(language + "-")
                    || language.hasPrefix(hint + "-")
                    || hint.localizedStandardContains(languageName(for: language))
            }) {
                languageScore = max(languageScore, weight - 10)
            }
        }
        guard languageScore > 0 else { return 0 }

        var result = languageScore * 1_000
        if hints.contains(where: { $0.contains("original") }) {
            result += 500
        }
        if hints.contains(where: { $0.contains("dub") }) {
            result -= 500
        }
        return result
    }

    private static func audioLanguageHints(for option: AVMediaSelectionOption) -> [String] {
        [
            option.extendedLanguageTag,
            option.locale?.identifier,
            option.displayName,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { $0.replacingOccurrences(of: "_", with: "-").lowercased() }
    }

    private static func preferredLanguagesWithEnglishFallback(_ preferredLanguages: [String]) -> [String] {
        var output: [String] = []
        for language in preferredLanguages.flatMap(languageCandidates) where !output.contains(language) {
            output.append(language)
        }
        for language in ["en-us", "en"] where !output.contains(language) {
            output.append(language)
        }
        return output
    }

    private static func languageCandidates(_ identifier: String) -> [String] {
        let lower = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        var output = [lower]
        if let base = lower.split(separator: "-").first {
            output.append(String(base))
        }
        return output
    }

    private static func languageName(for language: String) -> String {
        let base = language.split(separator: "-").first.map(String.init) ?? language
        return Locale(identifier: "en_US").localizedString(forLanguageCode: base)?.lowercased() ?? base
    }
}
