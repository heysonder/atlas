import SwiftUI
import UIKit

/// A short progressive blur under the embedded player's bottom edge: the page
/// goes softly out of focus as it scrolls beneath the video instead of being
/// cut off by it. Blur only, no tint, strongest at the player and gone a few
/// points below.
struct EmbeddedPlayerEdgeBlur: View {
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far below the player the blur reaches.
    static let reach: CGFloat = 24
    /// Blur radius right at the player's edge.
    static let radius: CGFloat = 3.5

    var body: some View {
        ProgressiveBlur(radius: Self.radius)
            .frame(height: Self.reach)
            .opacity(isVisible ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isVisible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ProgressiveBlur: UIViewRepresentable {
    let radius: CGFloat

    func makeUIView(context: Context) -> ProgressiveBlurView {
        ProgressiveBlurView(radius: radius)
    }

    func updateUIView(_ view: ProgressiveBlurView, context: Context) {}
}

/// `UIVisualEffectView` supplies a backdrop layer that samples what is behind
/// it; its material filters are swapped for Core Animation's `variableBlur`,
/// whose mask image sets the radius per pixel. The material's tint layers are
/// hidden, so nothing is drawn but the blur. If the filter or the backdrop
/// can't be found, the view falls back to a gradient-masked thin material.
private final class ProgressiveBlurView: UIVisualEffectView {
    private let radius: CGFloat
    private var usesVariableBlur = false

    init(radius: CGFloat) {
        self.radius = radius
        super.init(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        isUserInteractionEnabled = false
        // UIKit rebuilds the effect's layers on appearance changes; re-apply.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ProgressiveBlurView, _) in
            view.applyBlur()
        }
        applyBlur()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyBlur()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !usesVariableBlur {
            mask?.frame = bounds
        }
    }

    private var backdropView: UIView? {
        subviews.first { String(describing: type(of: $0)).contains("Backdrop") }
    }

    private func applyBlur() {
        guard let backdropView, let filter = Self.makeVariableBlur(radius: radius) else {
            applyFallback()
            return
        }
        backdropView.layer.filters = [filter]
        // Full-resolution capture so the unblurred end stays crisp.
        if let scale = window?.screen.scale {
            backdropView.layer.setValue(scale, forKey: "scale")
        }
        for subview in subviews where subview !== backdropView {
            subview.alpha = 0
        }
        mask = nil
        usesVariableBlur = true
    }

    private func applyFallback() {
        usesVariableBlur = false
        guard mask == nil else { return }
        let maskView = UIImageView(image: UIImage(cgImage: Self.falloffMask))
        maskView.frame = bounds
        mask = maskView
    }

    private static func makeVariableBlur(radius: CGFloat) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: selector),
            let filter = filterClass.perform(selector, with: "variableBlur")?.takeUnretainedValue() as? NSObject
        else {
            return nil
        }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(falloffMask, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        return filter
    }

    /// Alpha 1 at the top easing to 0 at the bottom; the filter stretches it
    /// over the layer. Smoothstep, so neither end of the ramp shows as a line.
    private static let falloffMask: CGImage = {
        let height = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil, width: 1, height: height, bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            preconditionFailure("Could not create the edge blur mask context")
        }
        for row in 0..<height {
            // Core Graphics rows count up from the bottom.
            let t = CGFloat(row) / CGFloat(height - 1)
            let alpha = t * t * (3 - 2 * t)
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [0, 0, 0, alpha])!)
            context.fill(CGRect(x: 0, y: row, width: 1, height: 1))
        }
        guard let image = context.makeImage() else {
            preconditionFailure("Could not create the edge blur mask image")
        }
        return image
    }()
}
