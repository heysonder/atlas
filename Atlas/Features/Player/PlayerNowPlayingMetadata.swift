import AVFoundation
import PipedKit
import UIKit

enum PlayerNowPlayingMetadata {
    static func streaming(_ detail: VideoDetail, request: PlayRequest) -> [AVMetadataItem] {
        let descLen = HTMLText.plain(detail.description ?? "").count
        NSLog("Atlas.player: description length from instance = \(descLen) chars")
        return [
            item(.commonIdentifierTitle, detail.title ?? request.title),
            item(.iTunesMetadataTrackSubTitle, detail.uploader ?? request.uploader),
            item(.commonIdentifierDescription, HTMLText.plain(detail.description ?? ""))
        ].compactMap { $0 }
    }

    static func local(_ request: PlayRequest) -> [AVMetadataItem] {
        [
            item(.commonIdentifierTitle, request.title),
            item(.iTunesMetadataTrackSubTitle, request.uploader)
        ].compactMap { $0 }
    }

    static func attachArtwork(to item: AVPlayerItem, urlString: String?, base: [AVMetadataItem]) {
        guard let urlString, let url = URL(string: urlString) else { return }
        Task { [weak item] in
            let data: Data? = url.isFileURL
                ? try? Data(contentsOf: url)
                : (try? await URLSession.shared.data(from: url))?.0
            guard let data, let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.9) else { return }

            let art = AVMutableMetadataItem()
            art.identifier = .commonIdentifierArtwork
            art.value = jpeg as NSData
            art.dataType = kCMMetadataBaseDataType_JPEG as String
            art.extendedLanguageTag = "und"

            await MainActor.run {
                guard let item else { return }
                item.externalMetadata = base + [art]
            }
        }
    }

    private static func item(_ identifier: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
        guard let value, !value.isEmpty else { return nil }
        let metadata = AVMutableMetadataItem()
        metadata.identifier = identifier
        metadata.value = value as NSString
        metadata.extendedLanguageTag = "und"
        metadata.dataType = kCMMetadataBaseDataType_UTF8 as String
        return metadata
    }
}
