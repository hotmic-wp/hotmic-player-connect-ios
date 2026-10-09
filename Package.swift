// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HotMicPlayerCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "HotMicPlayerCore", targets: ["HotMicPlayerCore"]),
        .library(name: "HotMicPlayerCoreTesting", targets: ["HotMicPlayerCoreTesting"])
    ],
    dependencies: [
        .package(url: "https://github.com/hotmic-wp/hotmic-player-sdk", from: "1.0.0-rc.1"),
        .package(url: "https://github.com/hotmic-wp/hotmic-core-ios", from: "1.0.2")
    ],
    targets: [
        .target(name: "HotMicPlayerCore", dependencies: [
            .product(name: "HotMicPlayer", package: "hotmic-player-sdk"),
            .product(name: "HotMicCore", package: "hotmic-core-ios")
        ]),
        .target(name: "HotMicPlayerCoreTesting", dependencies: [
            "HotMicPlayerCore",
            .product(name: "HotMicPlayer", package: "hotmic-player-sdk"),
            .product(name: "HotMicCore", package: "hotmic-core-ios")
        ]),
        .testTarget(name: "HotMicPlayerCoreTests", dependencies: [
            "HotMicPlayerCore", "HotMicPlayerCoreTesting",
            .product(name: "HotMicPlayer", package: "hotmic-player-sdk"),
            .product(name: "HotMicCore", package: "hotmic-core-ios")
        ])
    ],
    swiftLanguageModes: [.v5]
)
