// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceTest",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VoiceTest",
            path: "Sources/VoiceTest",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
    ]
)
