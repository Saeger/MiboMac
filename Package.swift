// swift-tools-version:5.9
// SwiftPM manifest for development (`swift build`, or open in Xcode) and CodeQL analysis.
// To build the distributable MiboMac.app, use build.sh / package.sh.
import Foundation
import PackageDescription

// Same FFmpeg lookup as build.sh: $FF, or Homebrew on Apple Silicon / Intel.
let ffmpeg = Context.environment["FF"]
    ?? ["/opt/homebrew/opt/ffmpeg", "/usr/local/opt/ffmpeg"].first { FileManager.default.fileExists(atPath: $0) }
    ?? "/opt/homebrew/opt/ffmpeg"

let package = Package(
    name: "MiboMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CPlayer",
            path: "Sources/CPlayer",
            publicHeadersPath: ".",
            cSettings: [.unsafeFlags(["-I\(ffmpeg)/include"])],
            linkerSettings: [
                .unsafeFlags(["-L\(ffmpeg)/lib"]),
                .linkedLibrary("avformat"), .linkedLibrary("avcodec"), .linkedLibrary("avutil"),
                .linkedLibrary("swscale"), .linkedLibrary("swresample"),
            ]
        ),
        .executableTarget(
            name: "MiboMac",
            dependencies: ["CPlayer"],
            path: "Sources/App",
            exclude: ["Bridging-Header.h"]
        ),
    ]
)
