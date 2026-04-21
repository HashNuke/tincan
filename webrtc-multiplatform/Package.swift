// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "webrtc-multiplatform",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_11),
    ],
    products: [
        .library(name: "WebRTC", targets: ["WebRTC"]),
    ],
    targets: [
        .binaryTarget(name: "WebRTC", path: "WebRTC.xcframework"),
    ]
)
