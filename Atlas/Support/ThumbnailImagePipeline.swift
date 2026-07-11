import Foundation
import ImageIO
import PipedKit
import UIKit

actor ThumbnailImagePipeline {
    static let shared = ThumbnailImagePipeline()

    typealias Loader = @Sendable (URL, Int, PolicyHTTPClient?) async -> UIImage?

    private struct CacheKey: Hashable {
        let url: String
        let maxPixelDimension: Int
        let namespace: String
    }

    private struct InFlightLoad {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>]
    }

    private var cache: [CacheKey: UIImage] = [:]
    private var order: [CacheKey] = []
    private var totalCost = 0
    private var inFlight: [CacheKey: InFlightLoad] = [:]
    private let loader: Loader
    private let limiter: ImageWorkLimiter
    /// Evict by decoded byte cost (width × height × 4), not entry count.
    private let costLimit = 64 * 1024 * 1024

    init(maxConcurrentWork: Int = 4) {
        loader = { url, maxPixelDimension, client in
            await Self.fetchAndDecode(
                url: url,
                maxPixelDimension: maxPixelDimension,
                client: client)
        }
        limiter = ImageWorkLimiter(limit: maxConcurrentWork)
    }

    init(maxConcurrentWork: Int, loader: @escaping Loader) {
        self.loader = loader
        limiter = ImageWorkLimiter(limit: maxConcurrentWork)
    }

    func image(
        original: String?,
        upgraded: String?,
        displaySize: CGSize,
        scale: CGFloat,
        client: PolicyHTTPClient?,
        namespace: String
    ) async -> UIImage? {
        let maxPixelDimension = Self.maxPixelDimension(for: displaySize, scale: scale)
        let candidates = Self.candidateURLs(original: original, upgraded: upgraded)
        for url in candidates {
            let key = CacheKey(
                url: url.absoluteString,
                maxPixelDimension: maxPixelDimension,
                namespace: namespace)
            if let cached = cache[key] { return cached }
            guard
                let image = await coalescedImage(
                    for: key,
                    url: url,
                    maxPixelDimension: maxPixelDimension,
                    client: client)
            else {
                if Task.isCancelled { return nil }
                continue
            }
            return image
        }
        return nil
    }

    private func coalescedImage(
        for key: CacheKey,
        url: URL,
        maxPixelDimension: Int,
        client: PolicyHTTPClient?
    ) async -> UIImage? {
        if let cached = cache[key] { return cached }
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
                await self?.finishLoad(image, for: key, id: loadID)
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

    private func waitForLoad(for key: CacheKey, waiterID: UUID) async -> UIImage? {
        await withCheckedContinuation { continuation in
            guard !Task.isCancelled, var load = inFlight[key] else {
                continuation.resume(returning: cache[key])
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

    private func finishLoad(_ image: UIImage?, for key: CacheKey, id: UUID) {
        guard let load = inFlight[key], load.id == id else { return }
        inFlight.removeValue(forKey: key)
        if let image { insert(image, for: key) }
        for continuation in load.waiters.values {
            continuation.resume(returning: image)
        }
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

    private func insert(_ image: UIImage, for key: CacheKey) {
        guard cache[key] == nil else { return }
        cache[key] = image
        order.append(key)
        totalCost += Self.cost(of: image)
        while totalCost > costLimit, !order.isEmpty {
            if let evicted = cache.removeValue(forKey: order.removeFirst()) {
                totalCost -= Self.cost(of: evicted)
            }
        }
    }

    /// Estimated decoded footprint: 4 bytes per pixel.
    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else {
            return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        }
        return cgImage.width * cgImage.height * 4
    }

    private static func maxPixelDimension(for displaySize: CGSize, scale: CGFloat) -> Int {
        let measured = max(displaySize.width, displaySize.height) * max(scale, 1)
        guard measured.isFinite, measured > 0 else { return 768 }
        let bucket = Int((measured / 64).rounded(.up)) * 64
        return min(max(bucket, 128), 1_536)
    }

    private static func candidateURLs(original: String?, upgraded: String?) -> [URL] {
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
