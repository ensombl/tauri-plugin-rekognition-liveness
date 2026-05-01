use tauri::{command, AppHandle, Runtime};

use crate::models::*;
use crate::RekognitionLivenessExt;
use crate::Result;

#[command]
pub(crate) async fn detect_liveness<R: Runtime>(
    app: AppHandle<R>,
    payload: DetectLivenessRequest,
) -> Result<DetectLivenessResponse> {
    app.rekognition_liveness().detect_liveness(payload)
}
