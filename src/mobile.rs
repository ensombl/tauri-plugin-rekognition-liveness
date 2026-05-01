use serde::de::DeserializeOwned;
use tauri::{
    plugin::{PluginApi, PluginHandle},
    AppHandle, Runtime,
};

use crate::models::*;

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_rekognition_liveness);

/// Initializes the Kotlin or Swift plugin classes registered by the host app.
pub fn init<R: Runtime, C: DeserializeOwned>(
    _app: &AppHandle<R>,
    api: PluginApi<R, C>,
) -> crate::Result<RekognitionLiveness<R>> {
    #[cfg(target_os = "android")]
    let handle =
        api.register_android_plugin("app.tauri.rekognitionliveness", "RekognitionLivenessPlugin")?;
    #[cfg(target_os = "ios")]
    let handle = api.register_ios_plugin(init_plugin_rekognition_liveness)?;
    Ok(RekognitionLiveness(handle))
}

/// Access to the rekognition-liveness APIs.
pub struct RekognitionLiveness<R: Runtime>(PluginHandle<R>);

impl<R: Runtime> RekognitionLiveness<R> {
    pub fn detect_liveness(
        &self,
        payload: DetectLivenessRequest,
    ) -> crate::Result<DetectLivenessResponse> {
        // camelCase to match the @Command method names on Kotlin/Swift sides.
        self.0
            .run_mobile_plugin("detectLiveness", payload)
            .map_err(Into::into)
    }
}
