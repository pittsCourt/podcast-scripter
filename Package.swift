// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PodcastScripter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PodcastScripter",
            path: "Sources/PodcastScripter"
        )
    ]
)
