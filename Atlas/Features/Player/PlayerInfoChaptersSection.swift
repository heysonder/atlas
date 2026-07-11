import PipedKit
import SwiftUI

struct PlayerInfoChaptersSection: View {
    let chapters: [VideoChapter]
    let thumbnail: String?
    let onTimestampTap: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Chapters")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("\(chapters.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(chapters) { chapter in
                    chapterRow(chapter)
                }
            }
        }
    }

    private func chapterRow(_ chapter: VideoChapter) -> some View {
        let title = chapter.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter"
        return Button {
            onTimestampTap(chapter.start)
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    Thumbnail(
                        url: chapter.image ?? thumbnail,
                        networkScope: .selectedInstance
                    )
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(width: 84, height: 47)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text(Format.clock(chapter.start))
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(5)
                }

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skip to \(title) at \(Format.clock(chapter.start))")
    }
}
