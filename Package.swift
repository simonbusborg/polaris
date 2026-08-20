// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Polaris",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // In-app updates. Sparkle only installs a build whose Developer ID
        // signature matches the running one, so this is only possible now
        // that releases are signed.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Polaris",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Polaris"
        ),
        .testTarget(
            name: "PolarisTests",
            dependencies: ["Polaris"],
            path: "Tests/PolarisTests"
        )
    ]
)
