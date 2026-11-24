// swift-tools-version:5.9
import PackageDescription
import Foundation

// ONNX Runtime (it runs the word-timing model) comes as a prebuilt library: scripts/get_onnxruntime.sh puts it in vendor/onnxruntime,
// Sources/COnnx talks to it, and scripts/build_app.sh copies it into the app. Run the script once before `swift build`.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "StrataMusic",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "COnnx",
            path: "Sources/COnnx",
            cSettings: [.headerSearchPath("../../vendor/onnxruntime/include")]
        ),
        .executableTarget(
            name: "StrataMusic",
            dependencies: ["COnnx"],
            path: "Sources/StrataMusic",
            linkerSettings: [
                .unsafeFlags(["-L", "\(root)/vendor/onnxruntime/lib", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedLibrary("onnxruntime"),
                .linkedLibrary("c++")
            ]
        ),
        .testTarget(name: "StrataMusicTests", dependencies: ["StrataMusic"], path: "Tests/StrataMusicTests")
    ]
)
