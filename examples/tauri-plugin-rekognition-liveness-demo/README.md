# tauri-plugin-rekognition-liveness-demo

Standalone, fully self-driving demo of `tauri-plugin-rekognition-liveness`. Mints sessions and credentials with the AWS SDK directly inside the demo so the only dev-side input is your IAM access key + secret (persisted in `localStorage` after first paste).

## Prereqs

- A real Android device (or iOS device) — Liveness is mobile-only at runtime; desktop returns synthetic success.
- An IAM principal with `AmazonRekognitionFullAccess` (or narrower: `rekognition:CreateFaceLivenessSession`, `rekognition:GetFaceLivenessSessionResults`, `rekognition:StartFaceLivenessSession`). `sts:GetSessionToken` is granted to all IAM users by default — that's what the demo uses to derive temp creds.
- AWS region with Face Liveness available: `us-east-1`, `us-west-2`, `eu-west-1`, `ap-northeast-1`, `ap-south-1`.

## Run

```bash
# 1. From the plugin root, build the JS API once (the demo links it).
cd packages/tauri-plugin-rekognition-liveness/
pnpm install
pnpm build                 # produces dist-js/

# 2. Now boot the demo.
cd examples/tauri-plugin-rekognition-liveness-demo
pnpm install

# Desktop (returns synthetic success — useful for JS-side iteration)
pnpm tauri dev

# Android (real device, USB debugging on)
pnpm tauri android init    # one-time scaffold — creates src-tauri/gen/android/
pnpm tauri android dev

# iOS (real device, signed)
pnpm tauri ios init        # one-time scaffold — creates src-tauri/gen/apple/
pnpm tauri ios dev
```

> **After every `tauri android init`** the auto-generated `src-tauri/gen/android/app/build.gradle.kts` needs **core library desugaring enabled** for the Amplify Liveness deps. The repo ships this patch already applied; if you regenerate, re-apply:
>
> - Add to the `android { ... }` block:
>   ```kotlin
>   compileOptions {
>       isCoreLibraryDesugaringEnabled = true
>       sourceCompatibility = JavaVersion.VERSION_1_8
>       targetCompatibility = JavaVersion.VERSION_1_8
>   }
>   ```
> - Add to the `dependencies { ... }` block:
>   ```kotlin
>   coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
>   ```

## What you do in the UI

The demo asks for three fields, paste-once-and-forget:

| Field | Value |
|---|---|
| Region | `us-east-1` (or any other Liveness-supported region) |
| Access key ID | `AKIA…` from your IAM user |
| Secret access key | the matching secret |

Tap **Run Liveness**. The demo, in order:

1. `STS:GetSessionToken` → 15-min temp credentials
2. `Rekognition:CreateFaceLivenessSession` → SessionId
3. Plugin's `detectLiveness({sessionId, region, credentials})` → native Compose / SwiftUI flow takes over the screen
4. On `status: 'success'`: `Rekognition:GetFaceLivenessSessionResults` → confidence + status

The demo screen then renders the plugin's status object plus the AWS verdict (status, confidence, audit-image count). On failure / cancel / error, you just see the plugin result without the AWS fetch.

## Expected outcomes

| Scenario | `pluginResult.status` | `livenessResults.Status` | `Confidence` |
|---|---|---|---|
| Real face | `success` | `SUCCEEDED` | typically > 90 |
| Printed photo / spoof | `failed` | (not fetched) | — |
| Hardware back / swipe down mid-session | `cancelled` | (not fetched) | — |
| App backgrounded mid-session | `cancelled` | (not fetched) | — |
| Genuine face but quality issue | `success` | `SUCCEEDED` but `Confidence` low | < threshold |

## Bundle inspection sanity-check

Confirms the production-shape contract — Svelte JS bundle stays clean of the React/Amplify React stack:

```bash
pnpm build
ls dist/assets/                # contains AWS SDK chunks (used by demo) but
                               # NO @aws-amplify/ui-react-liveness, NO react,
                               # NO react-dom, NO face-api.js
```

The Amplify Liveness deps that actually drive the camera live entirely inside the Tauri plugin's native code — never the JS bundle.

## Why long-lived IAM creds in the demo are fine here, but never in production

This demo persists a long-lived IAM access key in localStorage. **Don't replicate this in a shipping app.** In certless's real integration, the backend mints temp creds via `STS:AssumeRole` against a least-privilege role and returns them to the plugin — the device never holds long-lived credentials. The demo cuts that out for dev convenience.
