import AVFoundation
import CoreImage
import SwiftUI

/// Extends the live video's bottom edge into the watch page, preserving its
/// left-to-right colors with a slow, steady response to scene changes.
struct EmbeddedVideoEdgeBlur: View {
    let layerView: EmbeddedPlayerLayerView
    let isVisible: Bool
    let isPiPActive: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var edgeColors: [Color] = []

    private var shouldSample: Bool {
        isVisible && scenePhase == .active && !isPiPActive
    }

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: edgeColors.isEmpty ? [.black] : edgeColors,
                        startPoint: .leading, endPoint: .trailing)
                )
                // SwiftUI interpolates the palette at display refresh rate,
                // independently of the deliberately slower video sampling.
                .animation(reduceMotion ? nil : .linear(duration: 0.1), value: edgeColors)
                // Most of the color band sits above the page, under the player.
                // Its Gaussian tail diffuses into the background naturally;
                // no opacity-gradient mask or hard-ended strip.
                .frame(width: geometry.size.width + 64, height: 80)
                .offset(x: -32, y: -72)
                .blur(radius: 16)
        }
        .frame(height: 48)
        .clipped()
        .opacity(isVisible && !edgeColors.isEmpty ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isVisible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: edgeColors.isEmpty)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: shouldSample) {
            guard shouldSample else { return }
            await sampleEdge()
        }
    }

    /// The output shares the player's decoded frames; there is no second
    /// player or network request. Only a tiny strip is rendered, at 10 Hz,
    /// and the output is detached when the blur is hidden or leaves the screen.
    private func sampleEdge() async {
        let output = AVPlayerItemVideoOutput(
            pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let context = CIContext(options: [.cacheIntermediates: false])
        var attachedItem: AVPlayerItem?
        var transform = CGAffineTransform.identity
        var smoother = EmbeddedEdgeColorSmoother()
        var latestColors: [UInt8]?
        defer { attachedItem?.remove(output) }

        while !Task.isCancelled {
            let item = layerView.playerLayer.player?.currentItem
            if item !== attachedItem {
                attachedItem?.remove(output)
                attachedItem = item
                edgeColors = []
                transform = .identity
                smoother = EmbeddedEdgeColorSmoother()
                latestColors = nil
                if let item {
                    item.add(output)
                    if let track = try? await item.asset.loadTracks(withMediaType: .video).first {
                        transform = (try? await track.load(.preferredTransform)) ?? .identity
                    }
                    guard !Task.isCancelled else { return }
                    // A fallback or queue transition may replace the item
                    // while its track metadata is loading.
                    guard item === layerView.playerLayer.player?.currentItem else { continue }
                }
            }

            if let item, item.status == .readyToPlay {
                let time = item.currentTime()
                if output.hasNewPixelBuffer(forItemTime: time),
                    let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
                {
                    latestColors = makeEdgeColors(buffer, transform: transform, context: context)
                }
            }
            // Finish easing toward the final palette even when playback pauses.
            if let latestColors {
                let steadyColors = smoother.update(latestColors)
                edgeColors = stride(from: 0, to: steadyColors.count, by: 4).map { index in
                    Color(
                        .sRGB, red: steadyColors[index] / 255,
                        green: steadyColors[index + 1] / 255, blue: steadyColors[index + 2] / 255)
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }

    private func makeEdgeColors(
        _ buffer: CVPixelBuffer, transform: CGAffineTransform, context: CIContext
    ) -> [UInt8]? {
        let layer = layerView.playerLayer
        let bounds = layer.bounds
        let videoRect = layer.videoRect
        guard bounds.width > 0, bounds.height > 0, !videoRect.isEmpty else { return nil }

        // Track transforms use top-left coordinates; Core Image uses bottom-left.
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        let source = CIImage(cvPixelBuffer: buffer)
            .transformed(by: flip.concatenating(transform).concatenating(flip))
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scale = 96 / bounds.width
        let strip = CGRect(x: 0, y: 0, width: 96, height: max(1, bounds.height * scale * 0.035))
        let positioned =
            source
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(
                by: CGAffineTransform(
                    scaleX: videoRect.width * scale / extent.width,
                    y: videoRect.height * scale / extent.height)
            )
            .transformed(
                by: CGAffineTransform(
                    translationX: (videoRect.minX - bounds.minX) * scale,
                    y: (bounds.maxY - videoRect.maxY) * scale))
        // Include the player's actual black bars for portrait/letterboxed
        // video, rather than stretching picture colors across those edges.
        let image = positioned.composited(over: CIImage(color: .black)).cropped(to: strip)
        // A low-resolution color band keeps small moving details from becoming
        // distinct streaks in the glow.
        let band = image.transformed(by: CGAffineTransform(scaleX: 24 / strip.width, y: 1 / strip.height))
        var colors = [UInt8](repeating: 0, count: 24 * 4)
        colors.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                band, toBitmap: baseAddress, rowBytes: 24 * 4,
                bounds: CGRect(x: 0, y: 0, width: 24, height: 1), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return colors
    }
}

/// At 10 Hz, the five-sample median rejects objects/flashes lasting one or two
/// samples. Sustained changes then ease in over roughly 1–2 seconds rather than
/// snapping to each frame. Fractional values avoid rounding away small changes.
nonisolated struct EmbeddedEdgeColorSmoother {
    private var history: [[UInt8]] = []
    private var smoothed: [Double] = []

    mutating func update(_ colors: [UInt8]) -> [Double] {
        guard colors.count == smoothed.count, !history.isEmpty else {
            history = Array(repeating: colors, count: 5)
            smoothed = colors.map(Double.init)
            return smoothed
        }
        history.removeFirst()
        history.append(colors)
        for index in colors.indices {
            let median = history.map { $0[index] }.sorted()[2]
            smoothed[index] += (Double(median) - smoothed[index]) * 0.08
        }
        return smoothed
    }
}
