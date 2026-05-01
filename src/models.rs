use serde::{Deserialize, Serialize};

/// Short-lived AWS credentials minted by the consuming app's backend (e.g. via
/// `STS:AssumeRole` against a role with `rekognition:StartFaceLivenessSession`).
/// The plugin passes these straight through to the native Amplify SDK.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LivenessCredentials {
    pub access_key_id: String,
    pub secret_access_key: String,
    pub session_token: String,
    /// ISO 8601 expiry. Plugin doesn't refresh — caller is expected to mint
    /// credentials with TTL ≥ 5 minutes (Liveness session ≤3 min + setup).
    pub expires_at: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DetectLivenessRequest {
    /// SessionId from `CreateFaceLivenessSession` issued by the backend.
    pub session_id: String,
    /// AWS region the session was created in (must match the streaming endpoint).
    pub region: String,
    pub credentials: LivenessCredentials,
    /// Which device camera to use for capture. `"front"` (default) works with
    /// both `FaceMovementAndLightChallenge` (the AWS default, screen flashes a
    /// color sequence — only meaningful with the front camera) and
    /// `FaceMovementChallenge` (head movement only). `"back"` only works when
    /// the backend created the session with `Settings.ChallengePreferences =
    /// [{ Type: 'FaceMovementChallenge', ... }]`; with the light challenge
    /// the SDK forces front regardless of this hint.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub camera: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct DetectLivenessError {
    pub code: String,
    pub message: String,
}

/// Result of a single Liveness session run on-device. The reference image,
/// confidence score, and audit images are not returned through this channel —
/// the consuming app's backend retrieves them via `GetFaceLivenessSessionResults`
/// using the same `sessionId`.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DetectLivenessResponse {
    /// One of `success`, `failed`, `cancelled`, `error`.
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<DetectLivenessError>,
}
