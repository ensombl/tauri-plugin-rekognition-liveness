use tauri::{
    plugin::{Builder, TauriPlugin},
    Manager, Runtime,
};

pub use models::*;

#[cfg(desktop)]
mod desktop;
#[cfg(mobile)]
mod mobile;

mod commands;
mod error;
mod models;

pub use error::{Error, Result};

#[cfg(desktop)]
use desktop::RekognitionLiveness;
#[cfg(mobile)]
use mobile::RekognitionLiveness;

/// Extensions to [`tauri::App`], [`tauri::AppHandle`] and [`tauri::Window`] to access the rekognition-liveness APIs.
pub trait RekognitionLivenessExt<R: Runtime> {
    fn rekognition_liveness(&self) -> &RekognitionLiveness<R>;
}

impl<R: Runtime, T: Manager<R>> crate::RekognitionLivenessExt<R> for T {
    fn rekognition_liveness(&self) -> &RekognitionLiveness<R> {
        self.state::<RekognitionLiveness<R>>().inner()
    }
}

/// Initializes the plugin. Call this from your Tauri app's `lib.rs`:
///
/// ```ignore
/// .plugin(tauri_plugin_rekognition_liveness::init())
/// ```
pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("rekognition-liveness")
        .invoke_handler(tauri::generate_handler![commands::detect_liveness])
        .setup(|app, api| {
            #[cfg(mobile)]
            let rekognition_liveness = mobile::init(app, api)?;
            #[cfg(desktop)]
            let rekognition_liveness = desktop::init(app, api)?;
            app.manage(rekognition_liveness);
            Ok(())
        })
        .build()
}
