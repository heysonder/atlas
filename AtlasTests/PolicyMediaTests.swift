import Foundation
import PipedKit
import Testing

@testable import Atlas

@Test func detectsAV1HLSMasterManifest() {
    let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=11732129,CODECS="av01.0.12M.08,mp4a.40.2",RESOLUTION=3840x1920,FRAME-RATE=30,AUDIO="aac"
        /hls/av1/WOzcFkld6_g/video/401
        """

    #expect(StreamPlaybackBuilder.manifestAdvertisesAV1Video(manifest))
    #expect(!StreamPlaybackBuilder.manifestAdvertisesAV1Video("#EXTM3U\n#EXT-X-VERSION:7"))
}

@Test func policyMediaURLRoundTripPreservesSignedURLComponents() throws {
    let original = URL(
        string: "https://cdn.example.com/video/master.m3u8?token=a%2Bb%3D%3D&expires=42#track")!

    let encoded = try PolicyMediaAssetFactory.policyURL(for: original)
    let decoded = try PolicyMediaAssetFactory.originalURL(for: encoded)

    #expect(encoded.scheme == "atlas-https")
    #expect(decoded == original)
}

@Test func policyMediaRewritesNestedHLSReferencesThroughLoader() throws {
    let manifest = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",URI="../audio/index.m3u8?sig=a%2Bb"
        #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/key.bin?token=secret"
        #EXT-X-STREAM-INF:BANDWIDTH=1500000,AUDIO="aac"
          720/playlist.m3u8?expires=42
        """
    let base = URL(string: "https://cdn.example.com/path/master.m3u8?root=signed")!

    let data = try PolicyMediaAssetFactory.rewriteHLSManifest(
        Data(manifest.utf8),
        baseURL: base)
    let rewritten = try #require(String(data: data, encoding: .utf8))

    #expect(
        rewritten.contains(
            "URI=\"atlas-https://cdn.example.com/audio/index.m3u8?sig=a%2Bb\""))
    #expect(
        rewritten.contains(
            "URI=\"atlas-https://keys.example.com/key.bin?token=secret\""))
    #expect(
        rewritten.contains(
            "  atlas-https://cdn.example.com/path/720/playlist.m3u8?expires=42"))
}

@Test func policyMediaRejectsOversizeAndOverworkedHLSManifests() throws {
    let base = URL(string: "https://cdn.example.com/master.m3u8")!
    let oversize = Data(repeating: 65, count: PolicyMediaAssetFactory.maximumManifestInputBytes + 1)
    #expect(
        throws: PolicyMediaAssetFactory.ManifestError.inputTooLarge(
            maximumBytes: PolicyMediaAssetFactory.maximumManifestInputBytes)
    ) {
        _ = try PolicyMediaAssetFactory.rewriteHLSManifest(oversize, baseURL: base)
    }

    let attributeLine = #"#EXT-X-KEY:URI="a",URI="b",URI="c""#
    let overworked =
        (["#EXTM3U"]
        + Array(
            repeating: attributeLine,
            count: PolicyMediaAssetFactory.maximumManifestWorkUnits / 4 + 1
        )).joined(separator: "\n")
    #expect(
        throws: PolicyMediaAssetFactory.ManifestError.tooMuchWork(
            maximumUnits: PolicyMediaAssetFactory.maximumManifestWorkUnits)
    ) {
        _ = try PolicyMediaAssetFactory.rewriteHLSManifest(
            Data(overworked.utf8),
            baseURL: base)
    }
}

@Test func policyMediaRejectsAnHLSManifestWithTooManyLines() throws {
    let manifest =
        (["#EXTM3U"]
        + Array(
            repeating: "#EXT-X-DISCONTINUITY",
            count: PolicyMediaAssetFactory.maximumManifestLines
        )).joined(separator: "\n")

    #expect(
        throws: PolicyMediaAssetFactory.ManifestError.tooManyLines(
            maximum: PolicyMediaAssetFactory.maximumManifestLines)
    ) {
        _ = try PolicyMediaAssetFactory.rewriteHLSManifest(
            Data(manifest.utf8),
            baseURL: URL(string: "https://cdn.example.com/master.m3u8")!)
    }
}

@Test func policyMediaRejectsPrivateDestinationForPublicInstance() throws {
    let policy = NetworkDestinationPolicy(
        resolver: HostAddressResolver { host in
            host == "public.example" ? ["93.184.216.34"] : ["192.168.1.20"]
        })
    let context = try InstanceNetworkContext(
        instanceURL: URL(string: "https://public.example")!,
        policy: policy)
    let client = PolicyHTTPClient(context: context)

    #expect(throws: NetworkPolicyError.destinationNotAllowed) {
        _ = try PolicyMediaAssetFactory.asset(
            for: URL(string: "https://private.example/video.m3u8")!,
            client: client)
    }
}

@Test func policyMediaBuildsFiniteCheckedRangesAcrossLargeProgressiveMedia() throws {
    let first = try PolicyMediaAssetFactory.finiteMediaRange(
        offset: 0,
        remaining: PolicyMediaAssetFactory.maximumMediaBytes)
    let second = try PolicyMediaAssetFactory.finiteMediaRange(
        offset: first.upperBound + 1,
        remaining: PolicyMediaAssetFactory.maximumMediaBytes - Int64(first.count))
    let final = try PolicyMediaAssetFactory.finiteMediaRange(
        offset: PolicyMediaAssetFactory.maximumMediaBytes - 1,
        remaining: 1)

    #expect(first.lowerBound == 0)
    #expect(Int64(first.count) == PolicyMediaAssetFactory.mediaChunkBytes)
    #expect(second.lowerBound == PolicyMediaAssetFactory.mediaChunkBytes)
    #expect(final == (PolicyMediaAssetFactory.maximumMediaBytes - 1)...(PolicyMediaAssetFactory.maximumMediaBytes - 1))
    #expect(throws: PolicyMediaAssetFactory.MediaError.invalidRange) {
        _ = try PolicyMediaAssetFactory.finiteMediaRange(offset: Int64.max, remaining: Int64.max)
    }
}
