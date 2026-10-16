// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PodcastScripter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PodcastScripter",
            path: "Sources/PodcastScripter"
        ),
        .testTarget(
            name: "PodcastScripterTests",
            dependencies: ["PodcastScripter"],
            path: "Tests/PodcastScripterTests",
            resources: [.copy("matches-sample.json"), .copy("rankings-sample.json")]
        ),
    ]
)
