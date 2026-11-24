// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrataMusic",
    platforms: [.macOS(.v13)],
    targets: [
        // the small voice finder behind precise word timing (plain C, no libraries)
        .target(name: "CVoice", path: "Sources/CVoice"),
        .executableTarget(name: "StrataMusic", dependencies: ["CVoice"], path: "Sources/StrataMusic"),
        .testTarget(name: "StrataMusicTests", dependencies: ["StrataMusic", "CVoice"], path: "Tests/StrataMusicTests")
    ]
)
