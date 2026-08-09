// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HoloFrame",
    platforms: [.macOS(.v14)],
    targets: [
        // Private CoreGraphics virtual-display SPI. Objective-C because the interfaces
        // have no headers and must be re-declared — see virtualDisplay.md.
        .target(name: "CHoloFrame"),
        .executableTarget(
            name: "HoloFrame",
            dependencies: ["CHoloFrame"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
    ]
)
