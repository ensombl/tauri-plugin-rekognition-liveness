// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "tauri-plugin-rekognition-liveness",
    platforms: [
        // amplify-ui-swift-liveness requires iOS 14+; we target 14+ to match.
        .iOS(.v14),
        // Required because the vendored amplify-ui-swift-liveness depends on
        // amplify-swift, which requires macOS 12. SwiftPM enforces consistency:
        // a library declaring macOS X cannot depend on a library requiring
        // macOS Y > X. We're an iOS-only plugin in practice (Tauri WKWebView
        // is iOS only) but SwiftPM still validates the macOS minimum.
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "tauri-plugin-rekognition-liveness",
            type: .static,
            targets: ["tauri-plugin-rekognition-liveness"]),
    ],
    dependencies: [
        // Tauri runtime injected as a sibling local package by the Tauri CLI
        // when the consumer runs `tauri ios init` / `tauri ios dev`.
        .package(name: "Tauri", path: "../.tauri/tauri-api"),
        // AWS Amplify Liveness SwiftUI component — vendored.
        //
        // amplify-ui-swift-liveness 1.4.4's upstream Package.swift declares
        // only iOS 14 (no macOS) but depends on amplify-swift which requires
        // macOS 12, so SwiftPM resolution refuses with "the library
        // 'FaceLiveness' requires macos 10.13 ... AWSPluginsCore which
        // requires macos 12.0". We tried four cache-surgery workarounds
        // (in-checkout patch, bare-repo tag patch, fetch refspec clearing,
        // origin URL → file://self) — all of them got beaten by SwiftPM's
        // *fingerprint cache* at ~/Library/org.swift.swiftpm/security/
        // fingerprints/, which records a canonical SHA per (URL, version)
        // and rejects any resolved revision that doesn't match.
        //
        // Path-based deps are the only mechanism that bypasses fingerprint
        // validation entirely (SwiftPM treats them as unversioned local
        // packages). So we vendor the upstream source at tag 1.4.4 in
        // ../vendor/amplify-ui-swift-liveness/ with a one-line patch to
        // its Package.swift adding `.macOS(.v12)`, and reference it by
        // path instead of URL+version. When upstream releases a version
        // that declares macOS natively, replace this with a normal
        // `.package(url:..., from:...)` and remove the vendor/ dir.
        .package(name: "amplify-ui-swift-liveness", path: "../vendor/amplify-ui-swift-liveness"),
        // amplify-swift is the source of `AWSPluginsCore`, which defines the
        // `AWSCredentialsProvider` protocol that `FaceLivenessDetectorView.init`
        // accepts. SwiftPM doesn't auto-export transitive deps to consumers,
        // so we declare the same package directly here. Version pin matches
        // amplify-ui-swift-liveness 1.4.4's own pin (`from: "2.51.5"`); SwiftPM
        // unifies this against the transitive resolution.
        .package(url: "https://github.com/aws-amplify/amplify-swift", from: "2.51.5"),
    ],
    targets: [
        .target(
            name: "tauri-plugin-rekognition-liveness",
            dependencies: [
                .byName(name: "Tauri"),
                .product(name: "FaceLiveness", package: "amplify-ui-swift-liveness"),
                .product(name: "AWSPluginsCore", package: "amplify-swift"),
            ],
            path: "Sources"),
    ]
)
