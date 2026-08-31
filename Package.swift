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
        // Code both the app and the widget need. Small on purpose: the
        // snapshot they exchange, the formatting they must agree on, and the
        // string lookup. Nothing that talks to Polestar lives here — the
        // extension has no business holding a session.
        .target(
            name: "PolarisShared",
            path: "Sources/PolarisShared"
        ),
        .executableTarget(
            name: "Polaris",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "PolarisShared"
            ],
            path: "Sources/Polaris"
        ),
        // The widget is a second executable, hand-assembled into an .appex
        // the same way the .app itself is assembled — no Xcode project.
        //
        // -e _NSExtensionMain is what makes the binary loadable as an
        // extension: @main on the WidgetBundle still generates the SwiftUI
        // entry point, but the system starts an appex through
        // NSExtensionMain rather than main(). Xcode's widget template sets
        // exactly this flag. unsafeFlags is fine here and only here —
        // SwiftPM forbids it in a package consumed as a dependency, and
        // Polaris is only ever the root.
        .executableTarget(
            name: "PolarisWidget",
            dependencies: ["PolarisShared"],
            path: "Sources/PolarisWidget",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
            ]
        ),
        .testTarget(
            name: "PolarisTests",
            dependencies: ["Polaris", "PolarisShared"],
            path: "Tests/PolarisTests"
        )
    ]
)
