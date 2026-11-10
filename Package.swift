// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rim",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CMT",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "Rim",
            dependencies: ["CMT"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
