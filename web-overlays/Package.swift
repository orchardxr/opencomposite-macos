// swift-tools-version:6.0
// oc-webbroker and oc-webhelper: SteamVR-style web overlays (docs/web-overlays.md). Built by scripts/build.sh, which
// first builds the OpenXR loader (build/openxr-loader) the helper links against.
import Foundation
import PackageDescription

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let loader = "\(repo)/build/openxr-loader"

let package = Package(
    name: "OpenCompositeWebOverlays",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "oc-webbroker", targets: ["oc-webbroker"]),
        .executable(name: "oc-webhelper", targets: ["oc-webhelper"]),
    ],
    targets: [
        .target(
            name: "COverlayXR",
            cSettings: [.unsafeFlags(["-fno-objc-arc", "-I\(loader)/include", "-I\(repo)/third_party/openxr-sdk/include"])],
            linkerSettings: [
                .linkedFramework("Metal"),
                // The loader ships in runtime/bin/osx64; the helper is in runtime/libexec/opencomposite.
                .unsafeFlags(["-L\(loader)/src/loader", "-lopenxr_loader",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../bin/osx64"]),
            ]
        ),
        .executableTarget(name: "oc-webbroker", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "oc-webhelper", dependencies: ["COverlayXR"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
