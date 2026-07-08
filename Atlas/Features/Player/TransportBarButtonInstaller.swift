import AVKit
import UIKit

/// Attaches a custom button to `AVPlayerViewController`'s native transport
/// controls so it sits beside PiP / AirPlay / full-screen and auto-hides with
/// them.
///
/// iOS exposes no public API for this (custom transport-bar items are
/// tvOS-only, still true as of the iOS 27 SDK), so this reaches into the
/// controls' *private* view hierarchy: on each layout pass it locates the
/// busiest horizontal control row and appends the button if it isn't already
/// attached. Everything is guarded — if a future iOS reorganises the hierarchy
/// and the row can't be found, nothing is added (no crash; callers decide
/// whether to fall back to an overlay).
@MainActor
final class TransportBarButtonInstaller {
    private weak var button: UIButton?

    var isInstalled: Bool { button?.superview != nil }

    /// Attempts to (re)attach the button; call from `viewDidLayoutSubviews`.
    /// A no-op while the button from an earlier pass is still attached.
    func ensureInstalled(in root: UIView, makeButton: () -> UIButton) {
        guard !isInstalled else { return }

        let buttons = Self.allButtons(in: root)
        guard !buttons.isEmpty else { return }   // controls not built yet

        // Strategy 1: append to the horizontal stack holding the most buttons.
        if let row = Self.bestControlRow(in: root) {
            let button = makeButton()
            row.addArrangedSubview(button)
            self.button = button
            return
        }

        // Strategy 2 (no stack): sit beside the bottom-most control button, in its superview.
        guard let anchor = buttons.max(by: {
            let a = $0.convert($0.bounds, to: root), b = $1.convert($1.bounds, to: root)
            return (a.maxY, a.maxX) < (b.maxY, b.maxX)
        }), let bar = anchor.superview else { return }
        let button = makeButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: anchor.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: anchor.trailingAnchor, constant: 16)
        ])
        self.button = button
    }

    /// Places the button in the player's top bar, *beside* the leading
    /// (close / AirPlay) control cluster instead of inside it. The iOS 26
    /// Liquid Glass player wraps each control group in a compact capsule
    /// (`AVGlassBackedView` etc.) that AVKit sizes to exactly fit its own
    /// controls — a subview appended there renders past the capsule's bounds,
    /// visible but unreachable by hit-testing. So instead: find the
    /// leading-most visible control in the top bar, climb out of its compact
    /// capsule ancestors, and constrain our own 44pt glass button next to the
    /// capsule inside the larger container, which both hit-tests the spot and
    /// fades with the rest of the controls.
    func ensureInstalledBesideTopLeadingCluster(in root: UIView, makeButton: () -> UIButton) {
        guard !isInstalled else { return }

        func frame(_ v: UIView) -> CGRect { v.convert(v.bounds, to: root) }
        let controls = Self.allControls(in: root).filter {
            !$0.isHidden && $0.alpha > 0.1 && $0.window != nil
                && $0.bounds.width >= 20 && $0.bounds.height >= 20
        }
        guard !controls.isEmpty else { return }   // controls not built yet

        // Prefer the close/AirPlay cluster in the top half; fall back to the
        // leading-most control anywhere when the top bar isn't there.
        let top = controls.filter { frame($0).midY < root.bounds.midY }
        guard let anchor = (top.isEmpty ? controls : top)
            .min(by: { frame($0).midX < frame($1).midX }) else { return }

        var capsule: UIView = anchor
        while let parent = capsule.superview, parent !== root,
              parent.bounds.width <= 64 || parent.bounds.height <= 64 {
            capsule = parent
        }
        guard let container = capsule.superview else { return }

        let button = makeButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        let onTrailingSide = frame(capsule).midX >= root.bounds.midX
        NSLayoutConstraint.activate([
            onTrailingSide
                ? button.trailingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: -8)
                : button.leadingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: 8),
            button.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
        self.button = button
    }

    /// A circular Liquid Glass button matching the player's own control capsules.
    static func makeGlassControlButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> UIButton {
        var config = UIButton.Configuration.glass()
        config.image = UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        config.cornerStyle = .capsule
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.tintColor = .white
        button.accessibilityLabel = accessibilityLabel
        return button
    }

    private static func allControls(in root: UIView) -> [UIControl] {
        var found: [UIControl] = []
        func walk(_ v: UIView) {
            if let c = v as? UIControl { found.append(c) }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return found
    }

    /// A button styled to match the native transport controls.
    static func makeControlButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        button.setImage(UIImage(systemName: systemImage, withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = accessibilityLabel
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private static func allButtons(in root: UIView) -> [UIButton] {
        var found: [UIButton] = []
        func walk(_ v: UIView) {
            if let b = v as? UIButton { found.append(b) }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return found
    }

    /// The most likely transport-control row: the horizontal `UIStackView` with
    /// the most buttons, breaking ties toward the lowest one on screen (the
    /// bottom bar, where PiP / AirPlay / full-screen live).
    private static func bestControlRow(in root: UIView) -> UIStackView? {
        var best: UIStackView?
        var bestButtons = 0
        var bestY: CGFloat = 0
        func walk(_ v: UIView) {
            if let stack = v as? UIStackView, stack.axis == .horizontal {
                let buttons = stack.arrangedSubviews.reduce(into: 0) { count, sub in
                    if sub is UIButton { count += 1 }
                }
                if buttons > 0 {
                    let y = stack.convert(stack.bounds, to: root).maxY
                    if buttons > bestButtons || (buttons == bestButtons && y > bestY) {
                        best = stack; bestButtons = buttons; bestY = y
                    }
                }
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return best
    }
}

/// The full-screen player controller: places the **Info** control in the
/// native transport row, where it hides and shows with the rest of the
/// controls. If the private hierarchy can't be matched shortly after the
/// action is wired (a future iOS reshuffle), it reports failure once so the
/// presenter can fall back to the floating overlay pill instead — the Info
/// sheet is the only route to description/comments/queue, so it must never
/// silently disappear.
final class FullscreenPlayerController: AVPlayerViewController {
    /// Wired by the presenter once stream details are loaded (local playback
    /// has no info panel, so it never sets this and no button appears).
    var onInfoTap: (() -> Void)? {
        didSet {
            guard onInfoTap != nil else { return }
            startFallbackCountdownIfNeeded()
            viewIfLoaded?.setNeedsLayout()
        }
    }
    /// Fired once if the native row never materialised; also reflected in
    /// `infoButtonUnavailable` for wiring that happens after the countdown.
    var onInfoButtonUnavailable: (() -> Void)?
    private(set) var infoButtonUnavailable = false

    private let installer = TransportBarButtonInstaller()
    private var fallbackCountdown: Task<Void, Never>?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !infoButtonUnavailable, onInfoTap != nil else { return }
        installer.ensureInstalledBesideTopLeadingCluster(in: view) {
            TransportBarButtonInstaller.makeGlassControlButton(
                systemImage: "info",
                accessibilityLabel: "Info"
            ) { [weak self] in self?.onInfoTap?() }
        }
        if installer.isInstalled {
            fallbackCountdown?.cancel()
            fallbackCountdown = nil
        }
    }

    private func startFallbackCountdownIfNeeded() {
        guard fallbackCountdown == nil, !infoButtonUnavailable, !installer.isInstalled else { return }
        fallbackCountdown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, !self.installer.isInstalled else { return }
            self.infoButtonUnavailable = true
            self.onInfoButtonUnavailable?()
        }
    }
}
