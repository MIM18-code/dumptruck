// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dumptruck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DumptruckCore",
            path: "Sources/Dumptruck"
        ),
        .executableTarget(
            name: "Dumptruck",
            dependencies: ["DumptruckCore"],
            path: "Sources/DumptruckExecutable"
        ),
        .executableTarget(
            name: "ChecksRunner",
            dependencies: ["DumptruckCore"],
            path: "Sources/ChecksRunner"
        )
    ]
)
