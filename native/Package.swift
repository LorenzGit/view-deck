// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ViewDeckNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ViewDeckCore", targets: ["ViewDeckCore"]),
        .executable(name: "ViewDeckNative", targets: ["ViewDeckApp"]),
        .executable(name: "viewdeck", targets: ["ViewDeckCLI"])
    ],
    targets: [
        .target(
            name: "ViewDeckCore",
            path: "Sources/ViewDeckNative",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("WebKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "ViewDeckApp",
            dependencies: ["ViewDeckCore"]
        ),
        .executableTarget(
            name: "ViewDeckCLI",
            dependencies: ["ViewDeckCore"]
        ),
        .testTarget(name: "ViewDeckNativeTests", dependencies: ["ViewDeckCore"])
    ],
    swiftLanguageModes: [.v5]
)
