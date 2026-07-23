// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "screcord",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "screcord", targets: ["screcord"])
    ],
    targets: [
        .executableTarget(
            name: "screcord",
            path: "Sources/screcord"
        )
    ]
)
