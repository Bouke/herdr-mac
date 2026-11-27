// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HerdrMac",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "HerdrMac", targets: ["HerdrMac"]),
        .executable(name: "herdr-mac-probe", targets: ["herdr-mac-probe"]),
        .executable(name: "herdr-mac-attach", targets: ["herdr-mac-attach"]),
    ],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
        .target(name: "HerdrCore"),
        .target(
            name: "TerminalKit",
            dependencies: ["GhosttyKit", "HerdrCore"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(name: "HerdrMac", dependencies: ["HerdrCore", "TerminalKit"]),
        .executableTarget(name: "herdr-mac-probe", dependencies: ["HerdrCore"]),
        .executableTarget(name: "herdr-mac-attach", dependencies: ["HerdrCore"]),
        .testTarget(name: "HerdrCoreTests", dependencies: ["HerdrCore"]),
    ],
    swiftLanguageModes: [.v5]
)
