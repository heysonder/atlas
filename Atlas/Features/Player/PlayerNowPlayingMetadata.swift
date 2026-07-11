import AVFoundation
import PipedKit
import UIKit

enum PlayerNowPlayingMetadata {
    static func streaming(_ detail: VideoDetail, request: PlayRequest) -> [AVMetadataItem] {
        [
            item(.commonIdentifierTitle, detail.title ?? request.title),
            item(.iTunesMetadataTrackSubTitle, detail.uploader ?? request.uploader),
            item(.commonIdentifierDescription, HTMLText.plain(detail.description ?? "")),
        ].compactMap { $0 }
    }

    static func local(_ request: PlayRequest) -> [AVMetadataItem] {
        [
            item(.commonIdentifierTitle, request.title),
            item(.iTunesMetadataTrackSubTitle, request.uploader),
        ].compactMap { $0 }
    }

    static func attachArtwork(
        to item: AVPlayerItem,
        urlString: String?,
        base: [AVMetadataItem],
        client: PolicyHTTPClient
    ) {
        guard let urlString, let url = URL(string: urlString) else { return }
        Task { [weak item] in
            // Fetch, decode, and re-encode off the main actor — artwork can
            // be hundreds of KB and this runs at every playback start.
            let jpeg = await Task.detached { () async -> Data? in
                let data: Data?
                if url.isFileURL {
                    data = DownloadStore.contains(url) ? try? Data(contentsOf: url) : nil
                } else {
                    data = (try? await client.data(from: url))?.0
                }
                guard let data, let image = UIImage(data: data) else { return nil }
                return image.jpegData(compressionQuality: 0.9)
            }.value
            guard let jpeg, let item else { return }

            let art = AVMutableMetadataItem()
            art.identifier = .commonIdentifierArtwork
            art.value = jpeg as NSData
            art.dataType = kCMMetadataBaseDataType_JPEG as String
            art.extendedLanguageTag = "und"
            item.externalMetadata = base + [art]
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
