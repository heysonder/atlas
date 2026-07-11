import SwiftUI

struct CreatorAvatarCluster: View {
    private enum Slot {
        case avatar(Int)
        case overflow(Int)
    }

    private struct Placement {
        let slot: Slot
        let horizontalOffset: CGFloat
        let verticalOffset: CGFloat
        let diameter: CGFloat
        let rotation: Double
    }

    private let avatarURLs: [String?]
    private let colors: [Color] = [.blue, .pink, .teal, .orange]
    var additionalCount: Int = 0
    var size: CGFloat = 40

    private var extraCount: Int {
        CreatorCountPolicy.additional(additionalCount)
    }

    private var totalCount: Int {
        max(
            avatarURLs.count,
            CreatorCountPolicy.total(primaryCount: 1, additionalCount: extraCount))
    }

    private var side: CGFloat { size * 1.34 }

    private var placements: [Placement] {
        switch totalCount {
        case 2:
            return [
                placement(.avatar(1), x: 0.20, y: -0.16, diameter: 0.68, rotation: 8),
                placement(.avatar(0), x: -0.15, y: 0.14, diameter: 0.74, rotation: -6),
            ]
        case 3:
            return [
                placement(.avatar(1), x: 0.30, y: -0.18, diameter: 0.56, rotation: 9),
                placement(.avatar(2), x: -0.30, y: -0.10, diameter: 0.55, rotation: -10),
                placement(.avatar(0), x: 0.02, y: 0.18, diameter: 0.66, rotation: -4),
            ]
        default:
            let trailing: Slot = totalCount > 4 ? .overflow(totalCount - 3) : .avatar(3)
            return [
                placement(.avatar(1), x: 0.31, y: -0.22, diameter: 0.52, rotation: 9),
                placement(.avatar(2), x: -0.32, y: -0.13, diameter: 0.52, rotation: -9),
                placement(trailing, x: 0.24, y: 0.30, diameter: 0.50, rotation: 6),
                placement(.avatar(0), x: -0.05, y: 0.13, diameter: 0.64, rotation: -5),
            ]
        }
    }

    private var cluster: some View {
        ZStack {
            // Rendered back-to-front so the primary avatar lands last, on top.
            ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
                tile(placement)
            }
        }
        .frame(width: side, height: side)
    }

    private var ringColor: Color { Color(.systemBackground) }

    init(
        avatarURL: String?,
        collaboratorAvatarURLs: [String?] = [],
        additionalCount: Int = 0,
        size: CGFloat = 40
    ) {
        let urls = collaboratorAvatarURLs.isEmpty ? [avatarURL] : collaboratorAvatarURLs
        avatarURLs = urls.isEmpty ? [avatarURL] : urls
        self.additionalCount = additionalCount
        self.size = size
    }

    var body: some View {
        Group {
            if totalCount <= 1 {
                avatar(index: 0, size: size)
            } else {
                cluster
            }
        }
        .accessibilityHidden(true)
    }

    private func placement(
        _ slot: Slot,
        x: CGFloat,
        y: CGFloat,
        diameter: CGFloat,
        rotation: Double
    ) -> Placement {
        Placement(
            slot: slot,
            horizontalOffset: x,
            verticalOffset: y,
            diameter: diameter,
            rotation: rotation)
    }

    @ViewBuilder
    private func tile(_ placement: Placement) -> some View {
        let diameter = size * placement.diameter
        content(for: placement.slot, diameter: diameter)
            .overlay {
                Circle().strokeBorder(ringColor, lineWidth: max(1.5, diameter * 0.07))
            }
            .rotationEffect(.degrees(placement.rotation))
            .shadow(
                color: .black.opacity(0.18),
                radius: diameter * 0.05,
                x: 0,
                y: diameter * 0.04
            )
            .offset(
                x: size * placement.horizontalOffset,
                y: size * placement.verticalOffset)
    }

    @ViewBuilder
    private func content(for slot: Slot, diameter: CGFloat) -> some View {
        switch slot {
        case .avatar(let index):
            avatar(index: index, size: diameter)
        case .overflow(let count):
            countBubble(count, size: diameter)
        }
    }

    @ViewBuilder
    private func avatar(index: Int, size: CGFloat) -> some View {
        if index < avatarURLs.count {
            Avatar(url: avatarURLs[index], size: size, networkScope: .selectedInstance)
        } else {
            placeholder(index: index, size: size)
        }
    }

    private func placeholder(index: Int, size: CGFloat) -> some View {
        Circle()
            .fill(colors[index % colors.count])
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: max(8, size * 0.42), weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private func countBubble(_ count: Int, size: CGFloat) -> some View {
        Circle()
            .fill(Color.secondary)
            .frame(width: size, height: size)
            .overlay {
                Text("+\(count)")
                    .font(.system(size: max(8, size * 0.34), weight: .bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
            }
    }
}
