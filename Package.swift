// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MiniRec",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "MiniRec", path: "Sources/MiniRec")
    ],
    swiftLanguageModes: [.v5]
)
