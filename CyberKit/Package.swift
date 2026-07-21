// swift-tools-version: 6.0
//
// CyberKit — the typed Swift facade over the CyberRemesherAndUV C++ engine
// (design D1: all engine access goes through this layer; no mesh algorithms
// in Swift, no UI concepts in C++).
//
// The binary target is produced by `scripts/build_engine.sh`, which builds
// the engine submodule (Engine/CyberRemesherAndUV) into a static xcframework
// and copies it to Binaries/ (SwiftPM requires binary targets inside the
// package directory). Run that script once before building.
import PackageDescription

let package = Package(
    name: "CyberKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "CyberKit", targets: ["CyberKit"])
    ],
    targets: [
        // C ABI of the engine (capi/include/cyber_capi.h + module map),
        // static libs for ios-arm64 and ios-arm64-simulator.
        .binaryTarget(
            name: "CyberRemesherC",
            path: "Binaries/CyberRemesherC.xcframework"
        ),
        .target(
            name: "CyberKit",
            dependencies: ["CyberRemesherC"],
            linkerSettings: [
                // The engine is C++20; the C facade needs the C++ runtime
                // plus the frameworks used by the Metal compute backend.
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(
            name: "CyberKitTests",
            dependencies: ["CyberKit", "CyberRemesherC"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
