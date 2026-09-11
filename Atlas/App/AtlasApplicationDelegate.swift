import UIKit

/// Silent CloudKit pushes contain no library content. The coordinator still
/// checks enrollment and account identity before doing any work.
@MainActor
final class AtlasApplicationDelegate: NSObject, UIApplicationDelegate {
    static weak var cloudSync: CloudSyncCoordinator?

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let sync = Self.cloudSync else {
            completionHandler(.noData)
            return
        }
        let isForeground = application.applicationState == .active
        Task { @MainActor in
            let receivedChanges = await sync.handleRemoteNotification(isForeground: isForeground)
            completionHandler(receivedChanges ? .newData : .noData)
        }
    }
}
