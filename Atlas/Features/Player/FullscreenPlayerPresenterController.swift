import UIKit

/// Invisible host that presents the player and reports when it's dismissed.
final class FullscreenPlayerPresenterController: UIViewController {
    var onDismissed: (() -> Void)?

    private var presenting = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presenting && presentedViewController == nil {
            presenting = false
            onDismissed?()
        }
    }

    func presentModal(_ controller: UIViewController, completion: (() -> Void)? = nil) {
        presenting = true
        present(controller, animated: true, completion: completion)
    }
}
