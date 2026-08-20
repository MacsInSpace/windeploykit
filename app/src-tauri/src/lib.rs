mod acer_harvest;
mod sidecar;

use std::sync::Arc;

use tauri::{Manager, RunEvent};
use tracing_subscriber::EnvFilter;

use crate::acer_harvest::harvest_acer_sccm_urls;
use crate::sidecar::{check_pwsh_prerequisite, Sidecar, SidecarError, SidecarHandle, SidecarStatus, PwshPrerequisite};

#[tauri::command]
fn app_exit(app: tauri::AppHandle) {
    app.exit(0);
}

#[tauri::command]
async fn sidecar_invoke(
    state: tauri::State<'_, Arc<Sidecar>>,
    cmd: String,
    params: serde_json::Value,
) -> Result<serde_json::Value, SidecarError> {
    state.invoke(cmd, params).await
}

#[tauri::command]
async fn sidecar_restart(
    state: tauri::State<'_, Arc<Sidecar>>,
    spawn_env: Option<std::collections::HashMap<String, String>>,
) -> Result<(), SidecarError> {
    state.restart(spawn_env).await
}

#[tauri::command]
fn sidecar_status(state: tauri::State<'_, Arc<Sidecar>>) -> SidecarStatus {
    state.status()
}

#[tauri::command]
fn check_pwsh_prerequisite_cmd(app: tauri::AppHandle) -> PwshPrerequisite {
    check_pwsh_prerequisite(&app)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .with_target(false)
        .try_init();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .setup(|app| {
            let handle: SidecarHandle = app.handle().clone();
            let sidecar = Arc::new(Sidecar::new(handle.clone()));
            // Sidecar spawn is deferred until the JS shell calls sidecar_restart with
            // diagnostics env (APP_VERBOSE_LOGGING / APP_VERBOSE_POWERSHELL) from saved Settings.
            app.manage(sidecar);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            app_exit,
            sidecar_invoke,
            sidecar_restart,
            sidecar_status,
            check_pwsh_prerequisite_cmd,
            harvest_acer_sccm_urls
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if matches!(event, RunEvent::ExitRequested { .. } | RunEvent::Exit) {
                if let Some(state) = app.try_state::<Arc<Sidecar>>() {
                    state.exit();
                }
            }
        });
}
