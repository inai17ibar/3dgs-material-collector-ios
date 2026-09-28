// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MaterialCollector",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CaptureKit", targets: ["CaptureKit"])
    ],
    targets: [
        .target(
            name: "CaptureKit",
            path: "Sources/CaptureKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CaptureKitTests",
            dependencies: ["CaptureKit"],
            path: "Tests/CaptureKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
