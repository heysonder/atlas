import PipedKit
import SwiftUI

/// Title, meta line, and the description beneath the embedded player. Collapsed
/// it shows two lines of title and a single line of description; tapping
/// anywhere expands the full description (with tappable timestamps) and the
/// chapter list.
struct EmbeddedTitleBlock: View {
    let title: String
    let views: Int?
    let uploadedMillis: Int64?
    let isLive: Bool
    let description: String
    let chapters: [VideoChapter]
    let thumbnail: String?
    let onTimestampTap: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var metaText: String {
        if isLive {
            return Format.liveMetaLine(watching: views, startedMillis: uploadedMillis)
        }
        return Format.metaLine(Format.views(views), Format.relativeTime(uploadedMillis))
    }

    private var visibleChapters: [VideoChapter] {
        chapters.filter { $0.start >= 0 }.sorted { $0.start < $1.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if expanded {
                expandedContent
            } else {
                Button {
                    toggle()
                } label: {
                    collapsedContent
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the full description")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var collapsedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 2) {
                if !metaText.isEmpty {
                    Text(metaText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !description.isEmpty {
                        Text(description.collapsedLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("more")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !metaText.isEmpty {
                Text(metaText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if description.isEmpty {
                Text("No description.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                TimestampedText(text: description, onTimestampTap: onTimestampTap)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !visibleChapters.isEmpty {
                Divider()
                PlayerInfoChaptersSection(
                    chapters: visibleChapters,
                    thumbnail: thumbnail,
                    onTimestampTap: onTimestampTap)
            }
            Button {
                toggle()
            } label: {
                Text("Show less")
                    .font(.footnote.weight(.semibold))
                    .inlineTapTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    private func toggle() {
        if reduceMotion {
            expanded.toggle()
        } else {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
        }
    }
}

extension String {
    /// Newlines flattened so a two-line preview isn't spent on a blank line.
    fileprivate var collapsedLine: String {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
