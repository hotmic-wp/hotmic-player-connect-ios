// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HotMicPlayerConnect",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "HotMicPlayerConnect", targets: ["HotMicPlayerConnect"]),
        .library(name: "HotMicPlayerConnectTesting", targets: ["HotMicPlayerConnectTesting"])
    ],
    dependencies: [
        .package(url: "https://github.com/hotmic-wp/hotmic-player-sdk", from: "1.0.0-rc.1"),
        .package(url: "https://github.com/hotmic-wp/hotmic-core-ios", from: "1.0.2")
    ],
    targets: [
        .target(name: "HotMicPlayerConnect", dependencies: [
            .product(name: "HotMicPlayer", package: "hotmic-player-sdk"),
            .product(name: "HotMicCore", package: "hotmic-core-ios")
        ]),
        .target(name: "HotMicPlayerConnectTesting", dependencies: [
            "HotMicPlayerConnect",
            .product(name: "HotMicPlayer", package: "hotmic-player-sdk"),
            .product(name: "HotMicCore", package: "hotmic-core-ios")
        ]),
        .testTarget(name: "HotMicPlayerConnectTests", dependencies: [
            "HotMicPlayerConnect", "HotMicPlayerConnectTesting",
            .product(name: "HotMicPlayer", package: "hotmic-player-sdk"),
            .product(name: "HotMicCore", package: "hotmic-core-ios")
        ])
    ],
    swiftLanguageModes: [.v5]
)
