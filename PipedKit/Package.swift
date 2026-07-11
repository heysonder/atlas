// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PipedKit",
    platforms: [.iOS(.v26), .macOS(.v12)],
    products: [
        .library(name: "PipedKit", targets: ["PipedKit"])
    ],
    targets: [
        .target(name: "PipedKit"),
        .testTarget(name: "PipedKitTests", dependencies: ["PipedKit"]),
    ]
)
