# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — 2026-05-05

First public release on crates.io and npm under the `tauri-plugin-rekognition-liveness` /
`@ensombl/tauri-plugin-rekognition-liveness-api` names.

### Added

- `detectLiveness({ sessionId, region, credentials, camera, displayText? })` JS command
  that drives AWS Rekognition Face Liveness through native UI on Android (Jetpack
  Compose, via `@aws-amplify/ui-android-liveness`) and iOS (SwiftUI, via the vendored
  `amplify-ui-swift-liveness` with a macOS Catalyst patch). Camera capture and the
  AWS Streaming WebSocket run entirely on-device.
- `camera: 'front' | 'back'` parameter. Required for facility-gate flows where the
  operator points the rear lens at a third party — paired with `FaceMovementChallenge`
  on the API side because AWS's default `FaceMovementAndLightChallenge` only works
  with the user-facing camera.
- `displayText.centerFace` parameter to override the on-screen "Center your face"
  prompt. Useful when the operator is positioning a third party rather than
  self-scanning. Implemented on Android via a `Resources` subclass that intercepts
  the Amplify-emitted string lookup, and on iOS via `Bundle` swizzling so the
  override applies to `String(localized:bundle:)` calls inside the vendored Swift
  package without forking it.
- `tauri-plugin-rekognition-liveness setup` CLI (`scripts/setup.mjs`). Idempotently
  patches the consumer Tauri project for both platforms: `tauri.conf.json`
  (`bundle.iOS.minimumSystemVersion = "15.0"`), `build.rs` (16 KB page alignment for
  Google Play submissions from 2025-11-01), `gen/apple/project.yml` (deployment
  target, `LD_RUNPATH_SEARCH_PATHS`, `NSCameraUsageDescription`, SwiftPM resource
  bundle copy step), `gen/android/build.gradle.kts` (Kotlin 2.2.0 + Compose Compiler
  Gradle plugin), `gen/android/app/build.gradle.kts` (`isCoreLibraryDesugaringEnabled`
  + `desugar_jdk_libs >= 2.1.5`). Preserves a pre-existing
  `bundle.iOS.developmentTeam` value so the consumer's account-specific Apple team
  ID isn't overwritten on re-run.
- `scripts/bootstrap-ios-caches.sh` — partial-clones `aws-sdk-swift` into the SwiftPM
  cache before the first `pnpm tauri ios dev`. Without this, SwiftPM full-clones the
  ~5 GB aws-sdk-swift monorepo, which makes the first iOS build take 30+ minutes on
  a fresh laptop.
- Self-contained demo at `examples/tauri-plugin-rekognition-liveness-demo` that
  mints sessions and STS credentials inside the demo (using the user's IAM
  access key). Lets reviewers verify the plugin end-to-end without a backend.

### Changed

- **Renamed from `tauri-plugin-face-liveness` → `tauri-plugin-rekognition-liveness`**.
  The previous name implied generic face-liveness vendor support; the implementation
  is specific to AWS Rekognition Face Liveness. Crate, npm package, Cargo `links`,
  and Android namespace all updated. JS package is now scoped under `@ensombl/`.

### Fixed

- iOS first-build dyld failure (`libswift_Concurrency.dylib` not found) — the setup
  script now bumps `IPHONEOS_DEPLOYMENT_TARGET` to 15.0 and adds `/usr/lib/swift`
  to `LD_RUNPATH_SEARCH_PATHS` so the OS-shipped Swift runtime is linked instead of
  the back-deployed copy.
- Streaming WebSocket failures when the consumer page is served over a private
  LAN IP — these are not fixed in the plugin (AWS rejects such origins), but the
  demo README now points at Cloudflare Tunnel as the canonical workaround.
