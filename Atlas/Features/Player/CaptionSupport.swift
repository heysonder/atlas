import AVFoundation

enum PlayerCaptionSelection {
    static func keepOffByDefault(for item: AVPlayerItem) {
        Task { @MainActor in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            item.select(nil, in: group)
        }
    }
}
