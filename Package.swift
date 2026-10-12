// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kuhtake",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kuhtake",
            path: "Sources/Kuhtake",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
