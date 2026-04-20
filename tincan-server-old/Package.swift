// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TincanServer",
    platforms: [
       .macOS(.v14)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.0.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.6"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.22.0"),
    ],
    targets: [
        .executableTarget(
            name: "TincanServer",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            resources: [
                .copy("Resources/Models"),
                .copy("Resources/agent_profiles.json"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "TincanServerTests",
            dependencies: [
                .target(name: "TincanServer"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
