use serde::de::DeserializeOwned;
use tauri::{plugin::PluginApi, AppHandle, Runtime};

use crate::models::*;

pub fn init<R: Runtime, C: DeserializeOwned>(
    app: &AppHandle<R>,
    _api: PluginApi<R, C>,
) -> crate::Result<RekognitionLiveness<R>> {
    Ok(RekognitionLiveness(app.clone()))
}

/// Desktop stub. The Amplify Face Liveness UI is mobile-only (Compose / SwiftUI),
/// so on macOS / Windows / Linux the plugin returns a synthetic success so
/// `pnpm tauri dev` still exercises the JS contract end-to-end.
pub struct RekognitionLiveness<R: Runtime>(AppHandle<R>);

impl<R: Runtime> RekognitionLiveness<R> {
    pub fn detect_liveness(
        &self,
        _payload: DetectLivenessRequest,
    ) -> crate::Result<DetectLivenessResponse> {
        Ok(DetectLivenessResponse {
            status: "success".to_string(),
            error: None,
        })
    }
}
