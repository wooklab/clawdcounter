// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawdCounter",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CoreModels"),
        .target(name: "SessionsKit", dependencies: ["CoreModels"]),
        .target(name: "AuthKit", dependencies: ["CoreModels"]),
        .target(name: "UsageKit", dependencies: ["CoreModels"]),
        .target(name: "MenuBarUI", dependencies: ["CoreModels"]),
        .executableTarget(
            name: "ClawdCounter",
            dependencies: ["CoreModels", "SessionsKit", "AuthKit", "UsageKit", "MenuBarUI"]
        ),
        .executableTarget(name: "RenderPreview", dependencies: ["CoreModels", "MenuBarUI"]),
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels"]),
        .testTarget(name: "SessionsKitTests", dependencies: ["SessionsKit"]),
        .testTarget(name: "AuthKitTests", dependencies: ["AuthKit"]),
        .testTarget(name: "UsageKitTests", dependencies: ["UsageKit"]),
        .testTarget(name: "MenuBarUITests", dependencies: ["MenuBarUI", "CoreModels"]),
    ]
)
