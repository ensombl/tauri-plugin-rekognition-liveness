# tauri-plugin-rekognition-liveness

AWS Rekognition Face Liveness for Tauri 2 — exposes the native AWS Amplify Liveness UI on Android (Compose) and iOS (SwiftUI) through a single JS command. Camera capture and the WebSocket streaming connection to AWS Rekognition Streaming run entirely on the device; only `{sessionId, region, credentials}` flows in via Tauri IPC and only `{status, error?}` flows back.

## Why

Tauri's IPC is text-encoded. Streaming raw camera frames across the JS↔native boundary is unusably laggy. This plugin follows the official `@tauri-apps/plugin-barcode-scanner` pattern: native UI is sibling-inserted next to the WebView (not modal), one `Invoke` is held until completion, and AWS handles the streaming directly with the device's mobile internet — no proxying.

## Install

```bash
# JS half (workspace dep)
pnpm add tauri-plugin-rekognition-liveness-api
```

```toml
# Cargo (consumer Tauri app)
[dependencies]
tauri-plugin-rekognition-liveness = { path = "../../../packages/tauri-plugin-rekognition-liveness" }
```

```rust
// src-tauri/src/lib.rs
.plugin(tauri_plugin_face_liveness::init())
```

```json
// src-tauri/capabilities/default.json
{
  "permissions": ["core:default", "rekognition-liveness:default"]
}
```

## Project setup (one command)

Run from anywhere inside your Tauri project (auto-detects `src-tauri/`):

```bash
pnpm exec tauri-plugin-rekognition-liveness setup
```

Idempotent. Re-run after every `tauri ios init` / `tauri android init` — those commands regenerate `gen/apple` and `gen/android` from Tauri's templates and wipe the patches the plugin needs.

| File | What gets patched | Why |
|---|---|---|
| `src-tauri/tauri.conf.json` | `bundle.iOS.minimumSystemVersion = "15.0"` | Avoids embedding the back-deployed `libswift_Concurrency.dylib`, which dyld can't link against without `/usr/lib/swift` in the rpath. iOS 15+ ships the runtime in the OS. |
| `src-tauri/build.rs` | `-Wl,-z,max-page-size=16384` + `common-page-size=16384` for Android | Google Play requires 16 KB-aligned native libs for new submissions from 2025-11-01. |
| `src-tauri/gen/apple/project.yml` | `IPHONEOS_DEPLOYMENT_TARGET: 15.0`, `LD_RUNPATH_SEARCH_PATHS` adds `/usr/lib/swift`, `NSCameraUsageDescription` set, `Copy SwiftPM resource bundles` postCompileScripts entry | Required so dyld finds OS-shipped Swift libs, the Amplify Liveness UI gets camera access, and SwiftPM-emitted `*.bundle` directories (e.g. `AmplifyUILiveness_FaceLiveness.bundle` holding the BlazeFace `.mlmodelc`) end up in the `.app` for `Bundle.module` lookups. |
| `src-tauri/gen/android/build.gradle.kts` | Kotlin → 2.2.0, adds `compose-compiler-gradle-plugin` classpath | Amplify Liveness 1.7.0+ ships Kotlin 2.2.0 metadata; Compose 2.x needs the new gradle plugin. |
| `src-tauri/gen/android/app/build.gradle.kts` | `isCoreLibraryDesugaringEnabled = true`, `desugar_jdk_libs >= 2.1.5` | Amplify libs use `java.time.*`; Liveness 1.6.0+ AAR metadata requires desugar 2.1.5+. |

After patching `gen/apple/project.yml`, the script runs `xcodegen generate` to apply changes to the Xcode project (install via `brew install xcodegen` if missing). Patches to `tauri.conf.json` and `build.rs` survive `tauri ios/android init`; everything under `gen/` does not.

You'll also need a development team for code-signing — set `bundle.iOS.developmentTeam` in `tauri.conf.json` to your Apple team ID (10-char string from Apple Developer → Membership). The CLI doesn't auto-set this since it's account-specific.

For Android, add the Compose plugin to your consumer app module if you don't already use Compose:

```kotlin
// src-tauri/gen/android/app/build.gradle.kts
plugins {
    id("org.jetbrains.kotlin.plugin.compose")
}
```

The plugin's `AndroidManifest.xml` already declares `CAMERA` and `INTERNET` — Gradle's manifest merger pulls those into your consumer manifest automatically.

Pass `--dry-run` to preview without writing:

```bash
pnpm exec tauri-plugin-rekognition-liveness setup --dry-run
```

Patch a single platform:

```bash
pnpm exec tauri-plugin-rekognition-liveness setup ios
pnpm exec tauri-plugin-rekognition-liveness setup android
```

## iOS build setup (one-time)

`pnpm tauri ios dev` of any project that consumes this plugin transitively pulls **44+ git repos** for the SwiftPM dependency tree (Amplify Liveness → Amplify Swift → AWS SDK Swift → Smithy Swift → Apple's swift-nio family + crypto + etc.). On a cold cache that's ~5 GB of `aws-sdk-swift` alone over a single GitHub TCP stream — typically multi-hour. There are also several upstream issues that block the build entirely without local fixes.

The plugin ships a one-shot bootstrap script — invoke it via the CLI:

```bash
pnpm exec tauri-plugin-rekognition-liveness bootstrap-ios-caches
```

(Equivalent to running `packages/tauri-plugin-rekognition-liveness/scripts/bootstrap-ios-caches.sh` directly. Pass-through flags work, e.g. `bootstrap-ios-caches --force`.)

**Run it once before your first `pnpm tauri ios dev`.** Idempotent, parallelized, retrying. Subsequent iOS builds (this plugin, your apps that consume it, anything else on the same Mac that uses Amplify Liveness Swift) reuse the same caches.

### What the script does

| # | What | Why |
|---|---|---|
| 1 | Mirror-clones 32 SwiftPM transitive deps into `~/Library/Caches/org.swift.swiftpm/repositories/` and the plugin's `ios/.build/index-build/repositories/` | First build then resolves + checkouts from local disk; no GitHub fetch |
| 2 | Mirror-clones 12 `aws-crt-swift` git submodules (`aws-c-*`, `aws-checksums`, `s2n-tls`, `aws-verification-model-for-libcrypto`) into `~/Library/Caches/swiftpm-submodule-mirrors/` | aws-crt-swift uses git submodules, which `swift build` recursively pulls at checkout time |
| 3 | Sets `git config --global url.<local>.insteadOf <github>` for each submodule URL | Submodule clones transparently redirect to local mirrors instead of GitHub |
| 4 | Sets `git config --global protocol.file.allow always` | CVE-2022-39253 mitigation blocks `file://` transport in submodule clones by default; our `insteadOf` rewrites resolve to local file paths, so this whitelists them |
| 5 | Wipes stale SwiftPM workspace state (`Package.resolved`, `workspace-state.json`, `ios/.build/`, fingerprint cache for amplify-ui-swift-liveness) | Stale lockfiles from prior failed builds otherwise pin to upstream commits and conflict with the vendored path-based dep |
| 6 | Detects + repairs partial-cloned (`--filter=blob:none`) leftovers from earlier script versions, in both the user cache and per-target `swift-rs` caches | Partial clones break SwiftPM's `git checkout` of `aws-sdk-swift` specifically (~900k objects, lazy-fetch promisor stops working at scale) |

**The amplify-ui-swift-liveness macOS-platform bug is fixed structurally**, not via cache surgery. Upstream's `amplify-ui-swift-liveness 1.4.4` Package.swift declares only iOS 14 (no macOS) but depends on `amplify-swift` which requires macOS 12, so SwiftPM resolution refuses. We tried four cache-surgery workarounds (in-checkout edit, bare-repo tag patch, fetch-refspec clearing, origin URL → `file://self`) — all defeated by SwiftPM's *fingerprint cache* at `~/Library/org.swift.swiftpm/security/fingerprints/`, which records canonical SHAs per (URL, version) and rejects mismatches. The fix that actually works: vendor the upstream source at `packages/tauri-plugin-rekognition-liveness/vendor/amplify-ui-swift-liveness/` with a one-line `.macOS(.v12)` patch, reference it via `.package(name:..., path: "../vendor/amplify-ui-swift-liveness")`. Path-based deps bypass fingerprint validation entirely.

The script clones in parallel (default 6 concurrent) and shows a periodic progress dashboard. Total bootstrap time on a 100 Mbps line: **~30–50 minutes** on first run, dominated by `aws-sdk-swift`'s ~3 GB packfile through GitHub's single-stream throttle. Every subsequent run is sub-second (everything's cached).

### Flags

```bash
./bootstrap-ios-caches.sh                   # populate everything, skip what's already cached
./bootstrap-ios-caches.sh --force           # wipe and re-clone everything
./bootstrap-ios-caches.sh --user-only       # skip the per-plugin index-build cache
./bootstrap-ios-caches.sh --skip-submodules # skip submodule mirrors + git config rewrites
./bootstrap-ios-caches.sh --skip-patch      # skip the amplify-ui Package.swift patch
./bootstrap-ios-caches.sh --jobs N          # change parallel-clone cap (default 6)
./bootstrap-ios-caches.sh --undo            # remove the global git config changes
```

### What it touches outside the project

The script writes to four locations outside the repo:

```
~/Library/Caches/org.swift.swiftpm/repositories/      # SwiftPM standard cache (~3.5 GB after first run)
~/Library/Caches/swiftpm-submodule-mirrors/           # Side cache for aws-crt-swift submodules (~50 MB)
~/.gitconfig                                          # adds protocol.file.allow=always + ~12 url.X.insteadOf rules
<plugin>/ios/.build/index-build/repositories/         # Per-plugin SwiftPM cache (mirrors user cache)
```

`./bootstrap-ios-caches.sh --undo` reverses the `~/.gitconfig` changes. The disk caches stay until you `rm -rf` them — that's intentional, since they're shared across any project on the machine that builds against the same SwiftPM packages.

### Known errors this script avoids

| Symptom | Cause | What the script does |
|---|---|---|
| `pnpm tauri ios dev` hangs at `Script-XXXX.sh` for hours | First-time SwiftPM cloning ~5 GB of `aws-sdk-swift` over a single GitHub TCP stream | Pre-clones `aws-sdk-swift` (and 31 others) into the SwiftPM cache before the build runs |
| `error: unable to read sha1 file of Sources/Services/AWS<svc>/...` (thousands) | Partial-clone leftover from `--filter=blob:none` strategy that doesn't survive `swift-rs`'s nested SwiftPM `git checkout` | Detects partial-cloned dirs and replaces them with full mirrors |
| `error: the library 'FaceLiveness' requires macos 10.13, but depends on the product 'AWSPluginsCore' which requires macos 12.0` | Upstream bug in `amplify-ui-swift-liveness/Package.swift` (declares only iOS 14, no macOS minimum) | Force-updates the highest version tag in the local cache to a custom commit that adds `.macOS(.v12)` |
| `fatal: transport 'file' not allowed` during submodule clone | CVE-2022-39253 mitigation blocks `file://` clones (which our `insteadOf` redirects produce) | Sets `protocol.file.allow=always` globally |
| `git submodule update --init --recursive` clones `aws-crt-swift` submodules at ~1 MB/s for 90+ minutes | GitHub single-stream throttle on per-IP basis | Pre-clones submodule mirrors locally; `insteadOf` redirects future clones to local APFS clonefile (sub-second) |
| s2n-tls submodule mirror clone alone takes 90+ minutes | Full s2n-tls history is a few hundred MB, single-stream from GitHub | Shallow-clones s2n-tls with `--depth=1000` (gets the pinned commit's main-branch ancestors only, ~11 MB) |

### Vendor refresh

The amplify-ui-swift-liveness fix is committed source, not a runtime patch — `vendor/amplify-ui-swift-liveness/` contains upstream tag `1.4.4` with one line changed in its `Package.swift` (`platforms: [.iOS(.v14)]` → `platforms: [.iOS(.v14), .macOS(.v12)]`). When upstream releases a version that declares macOS 12 natively, refresh by:

```bash
# from packages/tauri-plugin-rekognition-liveness/
rm -rf vendor/amplify-ui-swift-liveness
mkdir -p vendor/amplify-ui-swift-liveness
git -C ~/Library/Caches/org.swift.swiftpm/repositories/amplify-ui-swift-liveness-2c84baec \
  archive <new-tag> | tar -x -C vendor/amplify-ui-swift-liveness/
# Verify the new upstream Package.swift declares macOS, then drop the path:
# dep entirely and revert ios/Package.swift to `.package(url:..., from:...)`.
```

### Quirks

- **Close Xcode and SwiftPM-aware editors before running the bootstrap.** SourceKit / sourcekit-lsp daemons re-resolve Swift packages in the background whenever they detect manifest changes; the script kills them during its workspace-state-wipe step, but closing IDEs first avoids races on the cache mirroring step too.
- **`Package.resolved` is regenerated on every build.** The amplify-ui-swift-liveness path dep is intentionally absent from it (path deps don't get pinned). If you see it pinned to an upstream URL+SHA, something else has resurrected the URL-based form — check `ios/Package.swift`.

### Refresh cadence

Re-run the script when:
- The plugin bumps `amplify-ui-swift-liveness` to a new major (the Package.swift patch binds to the highest tag in the cache; if upstream fixes the macOS declaration in a newer release, the patch is a no-op since `grep` won't match the broken pattern, but you may want to remove old patched tags via `--force`).
- A new transitive SwiftPM dep is added that's not in the script's hardcoded list (manifest as a `MISS` line in the script's index-build phase, or as a fresh GitHub clone in the build).
- aws-crt-swift bumps its s2n-tls submodule pin to a commit older than the past 1000 main-branch commits (very unlikely; manifest as `git submodule update --init --recursive` failing with "not our ref").

## Usage

```ts
import { detectLiveness } from 'tauri-plugin-rekognition-liveness-api';

// 1. Backend creates a session and mints scoped STS credentials.
const { sessionId, region, credentials } = await fetch('/api/liveness/start')
  .then((r) => r.json());

// 2. Native UI takes over, returns a single status when done.
const result = await detectLiveness({ sessionId, region, credentials });
//   → { status: 'success' | 'failed' | 'cancelled' | 'error', error?: { code, message } }

// 3. Backend retrieves the result + reference image via GetFaceLivenessSessionResults.
if (result.status === 'success') {
  await fetch(`/api/liveness/complete?sessionId=${sessionId}`, { method: 'POST' });
}
```

## Backend contract

The plugin does not call AWS itself. The consumer app's backend is responsible for:

1. **`CreateFaceLivenessSession`** — return `sessionId` + `region` to the client.
2. **`STS:AssumeRole`** — return short-lived credentials (TTL ≥ 5 minutes is recommended; Liveness session lasts up to 3 minutes plus streaming-setup time). The assumed role needs `rekognition:StartFaceLivenessSession` on `*`.
3. **`GetFaceLivenessSessionResults`** — call after the client signals `status: 'success'` to fetch the confidence score + reference image. Persist these in your audit trail.

### Front vs. rear camera

`detectLiveness({ ..., camera: 'front' | 'back' })` picks the device camera. Defaults to `'front'`. Use `'back'` for "verify someone else" flows (a guard scanning an arriving driver, a kiosk verifying a customer in front of it, etc.).

Rear camera **only works with the `FaceMovementChallenge`** — `FaceMovementAndLightChallenge` (the AWS default) flashes a color sequence on the screen for active anti-spoof, which is meaningless when the screen isn't facing the user. Both Amplify SDKs silently force the front camera in that case.

To opt the session into `FaceMovementChallenge`, pass `Settings.ChallengePreferences` when you call `CreateFaceLivenessSession`:

```ts
import { CreateFaceLivenessSessionCommand } from '@aws-sdk/client-rekognition';

await rekognition.send(new CreateFaceLivenessSessionCommand({
  Settings: {
    ChallengePreferences: [
      { Type: 'FaceMovementChallenge', Versions: { Minimum: '1.0.0', Maximum: '1.0.0' } },
    ],
  },
}));
```

Mismatch behaviour worth knowing:

| Backend session | `camera` arg | What runs |
|---|---|---|
| `FaceMovementAndLightChallenge` (default) | `'front'` (or omitted) | Light + movement, front camera. The strongest anti-spoof. |
| `FaceMovementAndLightChallenge` | `'back'` | SDK silently uses **front** anyway. The rear camera hint is ignored. |
| `FaceMovementChallenge` | `'front'` (or omitted) | Movement only, front camera. |
| `FaceMovementChallenge` | `'back'` | Movement only, **rear camera**. |

So picking `'back'` from the JS side is necessary but not sufficient — the backend has to opt in to `FaceMovementChallenge` too, or you lose the camera selection without an error.

## Runtime behaviour

- **Android**: hosts the Amplify `FaceLivenessDetector` Compose component as a sibling of the Tauri WebView. Hardware-back press → `cancelled`. App backgrounding → `cancelled`.
- **iOS**: hosts the Amplify `FaceLivenessDetectorView` SwiftUI view via `UIHostingController` inserted above the WKWebView. `UIApplication.willResignActiveNotification` → `cancelled`.
- **Desktop**: stub — returns `{ status: 'success' }` immediately so `pnpm tauri dev` on macOS/Windows/Linux exercises the JS contract without a device.

## Demo

`examples/tauri-plugin-rekognition-liveness-demo/` runs the plugin end-to-end against your own AWS account, no backend required. See its README.

## License

MIT.
