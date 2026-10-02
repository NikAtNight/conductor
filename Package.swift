// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Conductor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Conductor",
            path: "Sources/Conductor"
        ),
        .testTarget(
            name: "ConductorTests",
            dependencies: ["Conductor"],
            path: "Tests/ConductorTests"
        ),
    ]
)
