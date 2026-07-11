import SwiftUI

struct PlayerInfoDescriptionSection: View {
    let description: String
    @Binding var isExpanded: Bool
    let reduceMotion: Bool
    let onTimestampTap: (Int) -> Void

    /// Heuristic for whether the description is worth a Show more/less toggle —
    /// keeps comments reachable instead of buried under a wall of text.
    private var isDescriptionLong: Bool {
        description.count > 160 || description.filter { $0 == "\n" }.count >= 3
    }

    var body: some View {
        if description.isEmpty {
            Text("No description.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                TimestampedText(
                    text: description,
                    onTimestampTap: onTimestampTap
                )
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                if isDescriptionLong {
                    Button {
                        if reduceMotion {
                            isExpanded.toggle()
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        }
                    } label: {
                        Text(isExpanded ? "Show less" : "Show more")
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        }
    }
}
