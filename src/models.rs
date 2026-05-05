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

/// Optional UI-text overrides applied to the Amplify Liveness UI on this
/// session only. Useful when the operator-handed-the-device wording ("Center
/// your face") doesn't match the third-party-being-scanned context (e.g.
/// rear-camera gate verification — the camera doesn't face the user holding
/// the phone, it faces a driver).
///
/// Field naming is platform-neutral; the native bridges map each field to
/// the matching string id on Android / localizable key on iOS. Any field
/// left unset keeps the SDK's built-in copy.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LivenessDisplayText {
    /// Replaces the SDK's "Center your face" prompt shown on the get-ready /
    /// face-positioning screen.
    /// Android string id: `amplify_ui_liveness_get_ready_center_face_label`
    /// iOS localizable key: `amplify_ui_liveness_center_your_face_text`
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub center_face: Option<String>,
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
    /// Optional UI-text overrides. See {@link LivenessDisplayText} for the
    /// supported keys.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_text: Option<LivenessDisplayText>,
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
