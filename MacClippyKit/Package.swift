// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacClippyKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MacClippyCore", targets: ["MacClippyCore"]),
        .library(name: "MacClippyPlatform", targets: ["MacClippyPlatform"]),
        .executable(name: "macclippy", targets: ["macclippy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "MacClippyCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MacClippyCore"
        ),
        .executableTarget(
            name: "macclippy",
            dependencies: [
                "MacClippyCore",
            ],
            path: "Sources/macclippy"
        ),
        .target(
            name: "MacClippyPlatform",
            dependencies: [
                "MacClippyCore",
            ],
            path: "Sources/MacClippyPlatform"
        ),
        .testTarget(
            name: "MacClippyCoreTests",
            dependencies: [
                "MacClippyCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/MacClippyCoreTests"
        ),
        .testTarget(
            name: "MacClippyPlatformTests",
            dependencies: [
                "MacClippyPlatform",
                "MacClippyCore",
            ],
            path: "Tests/MacClippyPlatformTests"
        ),
    ]
)
