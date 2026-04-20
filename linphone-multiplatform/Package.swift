// swift-tools-version:5.9
import PackageDescription

// Local shim that re-exports linphonesw for both iOS and macOS.
// linphone-sdk-swift-ios and linphone-sdk-swift-macos are separate pre-built
// SPM packages — this wrapper picks the right one per platform.
let package = Package(
    name: "linphone-multiplatform",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_14),
    ],
    products: [
        .library(
            name: "LinphoneShim",
            targets: ["LinphoneShim"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://gitlab.linphone.org/BC/public/linphone-sdk-swift-ios",
            branch: "stable"
        ),
        .package(
            url: "https://gitlab.linphone.org/BC/public/linphone-sdk-swift-macos",
            branch: "stable"
        ),
    ],
    targets: [
        .target(
            name: "LinphoneShim",
            dependencies: [
                .product(
                    name: "linphonesw",
                    package: "linphone-sdk-swift-ios",
                    condition: .when(platforms: [.iOS])
                ),
                .product(
                    name: "linphonesw",
                    package: "linphone-sdk-swift-macos",
                    condition: .when(platforms: [.macOS])
                ),
            ]
        ),
    ]
)
