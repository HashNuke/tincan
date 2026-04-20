// swift-tools-version:5.9
import PackageDescription

// Self-contained multi-platform Linphone SDK package.
//
// Built from pre-compiled XCFrameworks sourced from:
//   linphone-sdk-swift-ios   5.4.108-pre.1+8d1944e957  (stable)
//   linphone-sdk-swift-macos 5.4.108-pre.1+8d1944e957  (stable)
//
// Common frameworks were merged (iOS + macOS slices combined into a single
// XCFramework) so that a universal app target can link against one package.
//
// Directory layout:
//   XCFrameworks/merged/    <- iOS arm64 + simulator + macOS arm64/x86_64
//   XCFrameworks/ios-only/  <- bctoolbox-ios, linphonetester, mbedcrypto/tls/x509
//   XCFrameworks/macos-only/<- ZXing
let package = Package(
    name: "linphone-multiplatform",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_14),
    ],
    products: [
        .library(name: "linphonesw", targets: ["linphonesw"]),
    ],
    targets: [
        // ── merged (iOS + macOS) ─────────────────────────────────────────
        .binaryTarget(name: "bctoolbox",      path: "XCFrameworks/merged/bctoolbox.xcframework"),
        .binaryTarget(name: "bctoolbox-tester", path: "XCFrameworks/merged/bctoolbox-tester.xcframework"),
        .binaryTarget(name: "belcard",        path: "XCFrameworks/merged/belcard.xcframework"),
        .binaryTarget(name: "belle-sip",      path: "XCFrameworks/merged/belle-sip.xcframework"),
        .binaryTarget(name: "belr",           path: "XCFrameworks/merged/belr.xcframework"),
        .binaryTarget(name: "lime",           path: "XCFrameworks/merged/lime.xcframework"),
        .binaryTarget(name: "linphone",       path: "XCFrameworks/merged/linphone.xcframework"),
        .binaryTarget(name: "mediastreamer2", path: "XCFrameworks/merged/mediastreamer2.xcframework"),
        .binaryTarget(name: "msamr",          path: "XCFrameworks/merged/msamr.xcframework"),
        .binaryTarget(name: "mscodec2",       path: "XCFrameworks/merged/mscodec2.xcframework"),
        .binaryTarget(name: "msopenh264",     path: "XCFrameworks/merged/msopenh264.xcframework"),
        .binaryTarget(name: "mssilk",         path: "XCFrameworks/merged/mssilk.xcframework"),
        .binaryTarget(name: "ortp",           path: "XCFrameworks/merged/ortp.xcframework"),
        // ── iOS-only ────────────────────────────────────────────────────
        .binaryTarget(name: "bctoolbox-ios",  path: "XCFrameworks/ios-only/bctoolbox-ios.xcframework"),
        .binaryTarget(name: "linphonetester", path: "XCFrameworks/ios-only/linphonetester.xcframework"),
        .binaryTarget(name: "mbedcrypto",     path: "XCFrameworks/ios-only/mbedcrypto.xcframework"),
        .binaryTarget(name: "mbedtls",        path: "XCFrameworks/ios-only/mbedtls.xcframework"),
        .binaryTarget(name: "mbedx509",       path: "XCFrameworks/ios-only/mbedx509.xcframework"),
        // ── macOS-only ──────────────────────────────────────────────────
        .binaryTarget(name: "ZXing",          path: "XCFrameworks/macos-only/ZXing.xcframework"),
        // ── glue target (mirrors linphonexcframeworks from upstream) ────
        .target(
            name: "linphonexcframeworks",
            dependencies: [
                "bctoolbox", "bctoolbox-tester", "belcard", "belle-sip", "belr",
                "lime", "linphone", "mediastreamer2", "msamr", "mscodec2",
                "msopenh264", "mssilk", "ortp",
                .target(name: "bctoolbox-ios",  condition: .when(platforms: [.iOS])),
                .target(name: "linphonetester", condition: .when(platforms: [.iOS])),
                .target(name: "mbedcrypto",     condition: .when(platforms: [.iOS])),
                .target(name: "mbedtls",        condition: .when(platforms: [.iOS])),
                .target(name: "mbedx509",       condition: .when(platforms: [.iOS])),
                .target(name: "ZXing",          condition: .when(platforms: [.macOS])),
            ]
        ),
        // ── Swift wrapper ────────────────────────────────────────────────
        .target(
            name: "linphonesw",
            dependencies: ["linphonexcframeworks"]
        ),
    ]
)
