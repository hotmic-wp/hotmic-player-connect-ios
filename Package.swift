// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HotMicPlayerCore",
    platforms: [.iOS(.v17)],
    products: [.library(name: "HotMicPlayerCore", targets: ["HotMicPlayerCore"])],
    dependencies: [
        .package(url: "https://github.com/hotmic-wp/hotmic-player-sdk", from: "0.4.1"),
        .package(url: "https://github.com/hotmic-wp/hotmic-core-ios", from: "1.0.2")
    ],
    targets: [
        .target(name: "HotMicPlayerCore", dependencies: [
            .product(name: "HotMicPlayer", package: "hotmic-player-sdk"),
            .product(name: "HotMicCore", package: "hotmic-core-ios")
        ]),
        .testTarget(name: "HotMicPlayerCoreTests", dependencies: [
            "HotMicPlayerCore",
            .product(name: "HotMicPlayer", package: "hotmic-player-sdk"),
            .product(name: "HotMicCore", package: "hotmic-core-ios")
        ])
    ],
    swiftLanguageModes: [.v5]
)
