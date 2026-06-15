import AVFoundation
import MediaAccessibility
import SwiftUI
import UIKit
import PipedKit

struct CaptionCue: Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String

    var isValid: Bool { start.isFinite && end.isFinite && end > start && !text.isEmpty }
}

@MainActor
@Observable
final class CaptionOverlayModel {
    var text: String?
    @ObservationIgnored private var cues: [CaptionCue] = []

    func reset() {
        cues = []
        text = nil
    }

    func setCues(_ cues: [CaptionCue]) {
        self.cues = cues.filter(\.isValid).sorted { $0.start < $1.start }
        text = nil
    }

    func update(at seconds: Double) {
        guard seconds.isFinite else {
            text = nil
            SystemMediaAccessibility.didDisplayCaptions(nil)
            return
        }
        let active = cues.last { seconds >= $0.start && seconds < $0.end }?.text
        if active != text {
            text = active
            SystemMediaAccessibility.didDisplayCaptions(active)
        }
    }
}

struct CaptionOverlayView: View {
    let model: CaptionOverlayModel
    var bottomPadding: CGFloat = 86
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let text = model.text, !text.isEmpty {
                Text(text)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(radius: 2)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: model.text)
    }
}

enum CaptionLoader {
    static func load(_ subtitle: Subtitle) async -> [CaptionCue] {
        guard let url = subtitle.usableURL else { return [] }
        return await load(url: url, mimeType: subtitle.mimeType)
    }

    static func load(url: URL, mimeType: String?) async -> [CaptionCue] {
        do {
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                data = try await URLSession.shared.data(from: url).0
            }
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .ascii)
            else { return [] }
            return CaptionParser.parse(text, mimeType: mimeType)
        } catch {
            return []
        }
    }
}

enum SystemMediaAccessibility {
    @MainActor
    static var shouldShowCaptions: Bool {
        UIAccessibility.isClosedCaptioningEnabled
            || MACaptionAppearanceGetDisplayType(.user) == .alwaysOn
    }

    static var preferredCaptionLanguages: [String] {
        let unmanaged = MACaptionAppearanceCopySelectedLanguages(.user)
        let selected = (unmanaged.takeRetainedValue() as NSArray).compactMap { $0 as? String }
        return selected.isEmpty ? Locale.preferredLanguages : selected
    }

    @MainActor
    static func didDisplayCaptions(_ text: String?) {
        guard let text, !text.isEmpty else {
            MACaptionAppearanceDidDisplayCaptions([] as CFArray)
            return
        }
        MACaptionAppearanceDidDisplayCaptions([text] as CFArray)
    }
}

enum CaptionParser {
    static func parse(_ text: String, mimeType: String?) -> [CaptionCue] {
        let lowerType = (mimeType ?? "").lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if lowerType.contains("vtt") || trimmed.hasPrefix("WEBVTT") {
            return parseWebVTT(trimmed)
        }
        if trimmed.hasPrefix("<") {
            return XMLCaptionParser.parse(Data(text.utf8))
        }
        return parseWebVTT(trimmed)
    }

    private static func parseWebVTT(_ text: String) -> [CaptionCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [CaptionCue] = []

        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex]
            let parts = timing.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTime(parts[0]),
                  let end = parseTime(parts[1].split(separator: " ").first.map(String.init) ?? parts[1])
            else { continue }
            let cueText = lines.dropFirst(timingIndex + 1)
                .map(stripCueMarkup)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cue = CaptionCue(start: start, end: end, text: cueText)
            if cue.isValid { cues.append(cue) }
        }
        return cues
    }

    fileprivate static func parseTime(_ raw: String?) -> Double? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        value = value.replacingOccurrences(of: ",", with: ".")
        if value.hasSuffix("ms") {
            return Double(value.dropLast(2).trimmingCharacters(in: .whitespaces)).map { $0 / 1000 }
        }
        if value.hasSuffix("s") {
            return Double(value.dropLast().trimmingCharacters(in: .whitespaces))
        }

        let parts = value.split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let component = Double(part) else { return nil }
            seconds = seconds * 60 + component
        }
        return seconds
    }

    private static func stripCueMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

private final class XMLCaptionParser: NSObject, XMLParserDelegate {
    private struct ActiveCue {
        let start: Double
        let end: Double
        var text = ""
    }

    private var cues: [CaptionCue] = []
    private var activeCue: ActiveCue?

    static func parse(_ data: Data) -> [CaptionCue] {
        let delegate = XMLCaptionParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.cues
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = elementName.lowercased()
        if element == "br", activeCue != nil {
            activeCue?.text.append("\n")
            return
        }
        guard element == "p" || element == "text" else { return }

        let start = CaptionParser.parseTime(attributeDict["begin"] ?? attributeDict["start"])
        let end = CaptionParser.parseTime(attributeDict["end"])
        let duration = CaptionParser.parseTime(attributeDict["dur"])
        guard let start else { return }
        activeCue = ActiveCue(start: start, end: end ?? start + (duration ?? 0))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        activeCue?.text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = elementName.lowercased()
        guard (element == "p" || element == "text"), let activeCue else { return }
        let text = activeCue.text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cue = CaptionCue(start: activeCue.start, end: activeCue.end, text: text)
        if cue.isValid { cues.append(cue) }
        self.activeCue = nil
    }
}
