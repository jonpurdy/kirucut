// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KiruCut",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "KiruCut", targets: ["KiruCutApp"])
    ],
    targets: [
        .executableTarget(
            name: "KiruCutApp",
            path: "Sources/KiruCutApp"
        )
    ]
)
