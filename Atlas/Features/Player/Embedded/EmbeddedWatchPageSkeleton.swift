import SwiftUI

/// Stands in for `EmbeddedWatchPage` while the stream resolves: the title the
/// feed already knew, with placeholder shapes where the meta line, channel
/// row, comments card, and related videos will land, so the page doesn't sit
/// empty and then pop in.
struct EmbeddedWatchPageSkeleton: View {
    let title: String
    let uploader: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleBlock
            channelRow
            block(height: 64, cornerRadius: 14)
            Divider()
            ForEach(0..<2, id: \.self) { _ in relatedCard }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .opacity(pulsing ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading \(title)")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            bar(width: 150)
            bar(width: 240)
        }
    }

    private var channelRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.quaternary)
                .frame(width: 36, height: 36)
            if let uploader, !uploader.isEmpty {
                Text(uploader)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            } else {
                bar(width: 120)
            }
            Spacer(minLength: 0)
            Capsule()
                .fill(.quaternary)
                .frame(width: 96, height: 32)
        }
    }

    private var relatedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            bar(width: 260)
            bar(width: 140)
        }
    }

    private func bar(width: CGFloat) -> some View {
        Capsule()
            .fill(.quaternary)
            .frame(maxWidth: width)
            .frame(height: 10)
    }

    private func block(height: CGFloat, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.quaternary)
            .frame(height: height)
    }
}
