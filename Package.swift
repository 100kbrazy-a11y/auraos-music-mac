// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrataMusic",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "StrataMusic", path: "Sources/StrataMusic")
    ]
)
