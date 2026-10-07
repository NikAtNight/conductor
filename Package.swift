// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Conductor",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates. Sparkle is a binary framework, so build-app.sh embeds and signs it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Conductor",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Conductor"
        ),
        .testTarget(
            name: "ConductorTests",
            dependencies: ["Conductor"],
            path: "Tests/ConductorTests"
        ),
    ]
)
