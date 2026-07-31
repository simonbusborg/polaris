// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Polaris",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Polaris",
            path: "Sources/Polaris"
        )
    ]
)
