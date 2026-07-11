import CoreGraphics
import Testing
import UIKit

@testable import Atlas

@MainActor
@Test func thumbnailPipelineCoalescesSameKeyAndLimitsGlobalWork() async {
    let probe = ImageLoadProbe()
    let pipeline = ThumbnailImagePipeline(maxConcurrentWork: 2) { url, _, _ in
        await probe.begin(url)
        try? await Task.sleep(for: .milliseconds(40))
        await probe.end()
        return UIImage()
    }

    async let first = pipeline.image(
        original: "https://example.com/same.jpg", upgraded: nil,
        displaySize: CGSize(width: 100, height: 100), scale: 2,
        client: nil, namespace: "test")
    async let second = pipeline.image(
        original: "https://example.com/same.jpg", upgraded: nil,
        displaySize: CGSize(width: 100, height: 100), scale: 2,
        client: nil, namespace: "test")
    _ = await (first, second)
    #expect(await probe.count(for: "https://example.com/same.jpg") == 1)

    await withTaskGroup(of: UIImage?.self) { group in
        for index in 0..<8 {
            group.addTask {
                await pipeline.image(
                    original: "https://example.com/\(index).jpg", upgraded: nil,
                    displaySize: CGSize(width: 100, height: 100), scale: 2,
                    client: nil, namespace: "test")
            }
        }
        for await _ in group {}
    }
    #expect(await probe.peakActive == 2)
}

@MainActor
@Test func thumbnailPipelineCancellationReleasesItsWaiter() async {
    let pipeline = ThumbnailImagePipeline(maxConcurrentWork: 1) { _, _, _ in
        try? await Task.sleep(for: .seconds(30))
        return Task.isCancelled ? nil : UIImage()
    }
    let load = Task {
        await pipeline.image(
            original: "https://example.com/cancel.jpg", upgraded: nil,
            displaySize: CGSize(width: 100, height: 100), scale: 2,
            client: nil, namespace: "test")
    }
    await Task.yield()
    load.cancel()
    #expect(await load.value == nil)
}

private actor ImageLoadProbe {
    private var counts: [String: Int] = [:]
    private var active = 0
    private(set) var peakActive = 0

    func begin(_ url: URL) {
        counts[url.absoluteString, default: 0] += 1
        active += 1
        peakActive = max(peakActive, active)
    }

    func end() {
        active -= 1
    }

    func count(for url: String) -> Int {
        counts[url, default: 0]
    }
}
