// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kuhtake",
    platforms: [.macOS(.v14)],
    targets: [
        // Native Blackmagic DeckLink/UltraStudio capture (DeckLink SDK, loaded from Desktop Video at run time).
        .target(
            name: "KuhtakeDeckLink",
            path: "Sources/KuhtakeDeckLink",
            exclude: ["sdk/README.md"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("sdk"),
                .unsafeFlags(["-fobjc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .executableTarget(
            name: "Kuhtake",
            dependencies: ["KuhtakeDeckLink"],
            path: "Sources/Kuhtake",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
