// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrataMusic",
    platforms: [.macOS(.v14)],
    dependencies: [
    ],
    targets: [
        // ONNX Runtime's prebuilt C library (what Microsoft's own Swift package wraps), used through Sources/COnnx
        .binaryTarget(
            name: "onnxruntime",
            url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip",
            checksum: "f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54"
        ),
        .target(name: "COnnx", dependencies: ["onnxruntime"], path: "Sources/COnnx"),
        .executableTarget(
            name: "StrataMusic",
            dependencies: ["COnnx"],
            path: "Sources/StrataMusic",
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreML"), .linkedFramework("Accelerate")]
        ),
        .testTarget(name: "StrataMusicTests", dependencies: ["StrataMusic"], path: "Tests/StrataMusicTests")
    ]
)
