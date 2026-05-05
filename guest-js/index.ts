import { invoke } from '@tauri-apps/api/core';

/**
 * Short-lived AWS credentials minted by the consuming app's backend
 * (e.g. via `STS:AssumeRole` against a role with
 * `rekognition:StartFaceLivenessSession`). The plugin passes these
 * straight through to the native Amplify Face Liveness SDK on the device —
 * they never round-trip through the Tauri IPC channel beyond the initial
 * `detectLiveness` call.
 */
export interface LivenessCredentials {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken: string;
  /** ISO 8601 expiry. Plugin doesn't refresh — supply credentials with
   * TTL ≥ ~5 minutes (Liveness session ≤3 min plus streaming setup time).
   */
  expiresAt: string;
}

/**
 * Which device camera to use for capture.
 *
 * - `"front"` (default) works with both `FaceMovementAndLightChallenge`
 *   (the AWS default — screen flashes a color sequence for anti-spoof,
 *   only meaningful when the screen and lens face the user) and
 *   `FaceMovementChallenge` (head movement only).
 * - `"back"` only takes effect when your backend created the session with
 *   `Settings.ChallengePreferences = [{ Type: 'FaceMovementChallenge',
 *   Versions: { Minimum: '1.0.0', Maximum: '1.0.0' } }]`. With the
 *   light challenge the Amplify SDK forces front regardless of this hint.
 */
export type LivenessCamera = 'front' | 'back';

/**
 * Per-session text overrides applied to the Amplify Liveness UI. Pass any
 * subset; unset fields keep the SDK's built-in copy. Useful for re-wording
 * prompts that don't fit your context — e.g. a rear-camera gate-verification
 * flow where "Center your face" reads as if it's about the operator instead
 * of the third party being scanned.
 *
 * The plugin maps each platform-neutral key here to the matching Amplify
 * resource on Android and localizable key on iOS, applies the override for
 * the duration of this `detectLiveness` call only, and clears it afterwards.
 */
export interface LivenessDisplayText {
  /**
   * Replaces the SDK's "Center your face" prompt shown on the get-ready /
   * face-positioning screen.
   */
  centerFace?: string;
}

export interface DetectLivenessRequest {
  /** SessionId returned by your backend's `CreateFaceLivenessSession` call. */
  sessionId: string;
  /** AWS region the session was created in (e.g. `"us-east-1"`). */
  region: string;
  credentials: LivenessCredentials;
  /**
   * Optional camera selection. Defaults to `"front"` if omitted.
   * See {@link LivenessCamera} for the back-camera caveat.
   */
  camera?: LivenessCamera;
  /**
   * Optional UI-text overrides for this session. See
   * {@link LivenessDisplayText} for the supported keys.
   */
  displayText?: LivenessDisplayText;
}

export type LivenessStatus = 'success' | 'failed' | 'cancelled' | 'error';

export interface DetectLivenessError {
  code: string;
  message: string;
}

export interface DetectLivenessResponse {
  status: LivenessStatus;
  error?: DetectLivenessError;
}

/**
 * Open the native AWS Face Liveness UI on the device, run the active
 * challenge, and resolve once with a discrete status. Camera frames and
 * the streaming WebSocket to AWS Rekognition Streaming stay entirely on
 * the device — only `{sessionId, region, credentials}` flows in via Tauri
 * IPC and only `{status, error?}` flows back.
 *
 * Your backend should retrieve the actual confidence score and reference
 * image via `GetFaceLivenessSessionResults` using the same `sessionId`
 * after this resolves with `status === 'success'`.
 *
 * On desktop (`pnpm tauri dev` on macOS/Windows/Linux) this returns a
 * synthetic `{ status: 'success' }` so the JS contract can be exercised
 * without a device or AWS creds.
 */
export async function detectLiveness(
  request: DetectLivenessRequest,
): Promise<DetectLivenessResponse> {
  return invoke<DetectLivenessResponse>(
    'plugin:rekognition-liveness|detect_liveness',
    { payload: request },
  );
}
