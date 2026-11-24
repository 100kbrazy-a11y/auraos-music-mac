// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrataMusic",
    platforms: [.macOS(.v14)],
    dependencies: [
        // ONNX Runtime, which runs the word-timing model (Aligner.swift)
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", exact: "1.24.2")
    ],
    targets: [
        .executableTarget(
            name: "StrataMusic",
            dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")],
            path: "Sources/StrataMusic",
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreML")]
        ),
        .testTarget(name: "StrataMusicTests", dependencies: ["StrataMusic"], path: "Tests/StrataMusicTests")
    ]
)
