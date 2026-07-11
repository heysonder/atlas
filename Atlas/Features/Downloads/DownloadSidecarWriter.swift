import Foundation
import UIKit

/// Performs sidecar validation and filesystem writes away from the main actor.
nonisolated enum DownloadSidecarWriter {
    static func writeThumbnail(_ data: Data, to destination: URL) -> Bool {
        guard UIImage(data: data) != nil else { return false }
        return write(data, to: destination)
    }

    static func write(_ data: Data, to destination: URL) -> Bool {
        (try? data.write(to: destination, options: .atomic)) != nil
    }
}
