import Foundation
import ImageIO
import PipedKit
import UIKit

actor ThumbnailImagePipeline {
    static let shared = ThumbnailImagePipeline()

    typealias Loader = @Sendable (URL, Int, PolicyHTTPClient?) async -> UIImage?

    struct LoadedImage: Sendable {
        let image: UIImage
        /// Mean colour of the decoded image, for a placeholder in its own tone.
        let averageColor: UIColor?
        let tone: ImageTone?
        /// True when served from the decoded in-memory cache; false when the
        /// call had to fetch (network, `URLCache`, or a downloaded file) and
        /// decode, or joined another caller's in-flight fetch.
        let fromMemoryCache: Bool
    }

    private struct CacheKey: Hashable {
        let url: String
        let maxPixelDimension: Int
        let namespace: String
    }

    private struct Entry: Sendable {
        let image: UIImage
        let tone: ImageTone?
        var averageColor: UIColor? { tone?.averageColor }
    }

    private struct InFlightLoad {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Entry?, Never>]
    }

    /// Decoded images behind a lock rather than actor isolation so a view can
    /// read them synchronously while building its body: a cache hit then
    /// renders in the row's first frame with no placeholder flash. Colour and
    /// edge info lives in `ImageToneStore` (main actor, observable).
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [CacheKey: Entry] = [:]
        private var order: [CacheKey] = []
        private var totalCost = 0
        private let costLimit: Int

        init(costLimit: Int) {
            self.costLimit = costLimit
        }

        func entry(for key: CacheKey) -> Entry? {
            lock.withLock { entries[key] }
        }

        func insert(_ entry: Entry, for key: CacheKey) {
            lock.withLock {
                guard entries[key] == nil else { return }
                entries[key] = entry
                order.append(key)
                totalCost += ThumbnailImagePipeline.cost(of: entry.image)
                while totalCost > costLimit, !order.isEmpty {
                    if let evicted = entries.removeValue(forKey: order.removeFirst()) {
                        totalCost -= ThumbnailImagePipeline.cost(of: evicted.image)
                    }
                }
            }
        }
    }

    private let store: Store
    private var inFlight: [CacheKey: InFlightLoad] = [:]
    private let loader: Loader
    private let limiter: ImageWorkLimiter
    /// Evict by decoded byte cost (width × height × 4), not entry count. A
    /// full-width feed thumbnail at 3x is ~3.3 MB, so this holds roughly a
    /// couple of screens' worth in each direction; 64 MB held only ~19 and
    /// re-fetched (and flashed) as soon as you scrolled back up.
    private static let costLimit = 192 * 1024 * 1024

    init(maxConcurrentWork: Int = 4) {
        loader = { url, maxPixelDimension, client in
            await Self.fetchAndDecode(
                url: url,
                maxPixelDimension: maxPixelDimension,
                client: client)
        }
        limiter = ImageWorkLimiter(limit: maxConcurrentWork)
        store = Store(costLimit: Self.costLimit)
    }

    init(maxConcurrentWork: Int, loader: @escaping Loader) {
        self.loader = loader
        limiter = ImageWorkLimiter(limit: maxConcurrentWork)
        store = Store(costLimit: Self.costLimit)
    }

    /// Synchronous memory-cache lookup for a view body. Returns nil without
    /// touching the network; call `load` to fetch.
    nonisolated func cachedImage(
        original: String?,
        upgraded: String?,
        displaySize: CGSize,
        scale: CGFloat,
        namespace: String
    ) -> LoadedImage? {
        let maxPixelDimension = Self.maxPixelDimension(for: displaySize, scale: scale)
        for url in Self.candidateURLs(original: original, upgraded: upgraded) {
            let key = CacheKey(
                url: url.absoluteString, maxPixelDimension: maxPixelDimension, namespace: namespace)
            if let entry = store.entry(for: key) {
                return LoadedImage(
                    image: entry.image, averageColor: entry.averageColor, tone: entry.tone, fromMemoryCache: true)
            }
        }
        return nil
    }

    func image(
        original: String?,
        upgraded: String?,
        displaySize: CGSize,
        scale: CGFloat,
        client: PolicyHTTPClient?,
        namespace: String
    ) async -> UIImage? {
        await load(
            original: original, upgraded: upgraded, displaySize: displaySize,
            scale: scale, client: client, namespace: namespace
        )?.image
    }

    func load(
        original: String?,
        upgraded: String?,
        displaySize: CGSize,
        scale: CGFloat,
        client: PolicyHTTPClient?,
        namespace: String
    ) async -> LoadedImage? {
        let maxPixelDimension = Self.maxPixelDimension(for: displaySize, scale: scale)
        let candidates = Self.candidateURLs(original: original, upgraded: upgraded)
        for url in candidates {
            let key = CacheKey(
                url: url.absoluteString,
                maxPixelDimension: maxPixelDimension,
                namespace: namespace)
            if let entry = store.entry(for: key) {
                return LoadedImage(
                    image: entry.image, averageColor: entry.averageColor, tone: entry.tone, fromMemoryCache: true)
            }
            guard
                let entry = await coalescedImage(
                    for: key,
                    url: url,
                    maxPixelDimension: maxPixelDimension,
                    client: client)
            else {
                if Task.isCancelled { return nil }
                continue
            }
            if let tone = entry.tone, let toneKey = original ?? upgraded {
                await MainActor.run { ImageToneStore.shared.set(tone, for: toneKey) }
            }
            return LoadedImage(
                image: entry.image, averageColor: entry.averageColor, tone: entry.tone, fromMemoryCache: false)
        }
        return nil
    }

    private func coalescedImage(
        for key: CacheKey,
        url: URL,
        maxPixelDimension: Int,
        client: PolicyHTTPClient?
    ) async -> Entry? {
        if let entry = store.entry(for: key) { return entry }
        if inFlight[key] == nil {
            let loadID = UUID()
            let loader = self.loader
            let limiter = self.limiter
            let task = Task { [weak self] in
                guard await limiter.acquire() else {
                    await self?.finishLoad(nil, for: key, id: loadID)
                    return
                }
                let image = await loader(url, maxPixelDimension, client)
                await limiter.release()
                let entry = await Self.entry(for: image)
                await self?.finishLoad(entry, for: key, id: loadID)
            }
            inFlight[key] = InFlightLoad(id: loadID, task: task, waiters: [:])
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await waitForLoad(for: key, waiterID: waiterID)
        } onCancel: {
            Task { await self.cancelWaiter(for: key, waiterID: waiterID) }
        }
    }

    private func waitForLoad(for key: CacheKey, waiterID: UUID) async -> Entry? {
        await withCheckedContinuation { continuation in
            guard !Task.isCancelled, var load = inFlight[key] else {
                continuation.resume(returning: store.entry(for: key))
                return
            }
            load.waiters[waiterID] = continuation
            inFlight[key] = load
        }
    }

    private func cancelWaiter(for key: CacheKey, waiterID: UUID) {
        guard var load = inFlight[key],
            let continuation = load.waiters.removeValue(forKey: waiterID)
        else {
            return
        }
        continuation.resume(returning: nil)
        if load.waiters.isEmpty {
            load.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = load
        }
    }

    private func finishLoad(_ entry: Entry?, for key: CacheKey, id: UUID) {
        guard let load = inFlight[key], load.id == id else { return }
        inFlight.removeValue(forKey: key)
        if let entry { store.insert(entry, for: key) }
        for continuation in load.waiters.values {
            continuation.resume(returning: entry)
        }
    }

    /// Pairs a decoded image with its tone, computed off the actor from one
    /// small (24×24) draw of the already-downsampled bitmap.
    nonisolated private static func entry(for image: UIImage?) async -> Entry? {
        guard let image else { return nil }
        let tone = await Task.detached(priority: .utility) { Self.tone(of: image) }.value
        return Entry(image: image, tone: tone)
    }

    private static let toneSampleSize = 24

    nonisolated private static func tone(of image: UIImage) -> ImageTone? {
        guard let cgImage = image.cgImage else { return nil }
        let side = toneSampleSize
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var sumR = 0
        var sumG = 0
        var sumB = 0
        var edgeLuma: [Double] = []
        edgeLuma.reserveCapacity(side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                let r = Int(rgba[i])
                let g = Int(rgba[i + 1])
                let b = Int(rgba[i + 2])
                sumR += r
                sumG += g
                sumB += b
                // The outermost ring is what meets the surface.
                if x == 0 || y == 0 || x == side - 1 || y == side - 1 {
                    edgeLuma.append((0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255)
                }
            }
        }
        let count = CGFloat(side * side)
        let average = UIColor(
            red: CGFloat(sumR) / count / 255, green: CGFloat(sumG) / count / 255,
            blue: CGFloat(sumB) / count / 255, alpha: 1)

        // Majority, not uniformity: a logo or a caption touching the border
        // shouldn't stop a mostly-black edge from getting its hairline.
        let total = Double(edgeLuma.count)
        let darkShare = Double(edgeLuma.filter { $0 < 0.16 }.count) / total
        let lightShare = Double(edgeLuma.filter { $0 > 0.84 }.count) / total
        let edge: ImageTone.Edge =
            darkShare >= 0.8 ? .dark : lightShare >= 0.8 ? .light : .mixed
        return ImageTone(averageColor: average, edge: edge)
    }

    nonisolated private static func fetchAndDecode(
        url: URL,
        maxPixelDimension: Int,
        client: PolicyHTTPClient?
    ) async -> UIImage? {
        if url.isFileURL {
            guard DownloadStore.contains(url),
                let data = try? Data(contentsOf: url)
            else {
                return nil
            }
            return await Task.detached(priority: .utility) {
                Self.downsample(data: data, maxPixelDimension: maxPixelDimension)
            }.value
        }
        guard let client else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await client.data(for: request),
            Self.isSuccessful(response)
        else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            Self.downsample(data: data, maxPixelDimension: maxPixelDimension)
        }.value
    }

    /// Estimated decoded footprint: 4 bytes per pixel.
    nonisolated fileprivate static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else {
            return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        }
        return cgImage.width * cgImage.height * 4
    }

    nonisolated private static func maxPixelDimension(for displaySize: CGSize, scale: CGFloat) -> Int {
        let measured = max(displaySize.width, displaySize.height) * max(scale, 1)
        guard measured.isFinite, measured > 0 else { return 768 }
        let bucket = Int((measured / 64).rounded(.up)) * 64
        return min(max(bucket, 128), 1_536)
    }

    nonisolated private static func candidateURLs(original: String?, upgraded: String?) -> [URL] {
        var seen = Set<String>()
        return [upgraded, original].compactMap { raw in
            guard let raw,
                !seen.contains(raw),
                let url = URL(string: raw)
            else {
                return nil
            }
            seen.insert(raw)
            return url
        }
    }

    private static func isSuccessful(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(http.statusCode)
    }

    private static func downsample(data: Data, maxPixelDimension: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let downsampleOptions =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

private actor ImageWorkLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var active = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < limit {
            active += 1
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
