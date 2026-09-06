mod acer_harvest;
mod sidecar;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, RunEvent, WindowEvent};
use tracing_subscriber::EnvFilter;

use crate::acer_harvest::harvest_acer_sccm_urls;
use crate::sidecar::{check_pwsh_prerequisite, Sidecar, SidecarError, SidecarHandle, SidecarStatus, PwshPrerequisite};

const TRAY_ID: &str = "main";
/// How long the webview gets to run its exit path after tray "Quit" before the host
/// exits anyway (RunEvent::ExitRequested still stops the sidecar either way).
const QUIT_GRACE_MS: u64 = 2500;

/// Window-close behaviour, the same shape as AdobeUpdateKit and USM: the close
/// button hides the window to the tray (Windows) / menu bar (macOS) so PXE and the
/// deployment share keep serving. Default on; the frontend pushes the saved
/// preference (lib/tray.ts, setting `window.closeToTray`) at boot and on change.
pub struct WindowPrefs {
    close_to_tray: AtomicBool,
}

/// Real exit (bypasses close-to-tray): File > Exit and the tray's Quit.
#[tauri::command]
fn app_exit(app: tauri::AppHandle) {
    app.exit(0);
}

#[tauri::command]
fn set_close_to_tray(state: tauri::State<'_, Arc<WindowPrefs>>, enabled: bool) {
    state.close_to_tray.store(enabled, Ordering::SeqCst);
}

/// Tray tooltip; the frontend appends the PXE server URL while it serves.
#[tauri::command]
fn set_tray_tooltip(app: AppHandle, text: String) -> Result<(), String> {
    match app.tray_by_id(TRAY_ID) {
        Some(tray) => tray.set_tooltip(Some(text)).map_err(|e| e.to_string()),
        None => Err("tray icon not available".to_string()),
    }
}

fn product_name(app: &AppHandle) -> String {
    app.config()
        .product_name
        .clone()
        .unwrap_or_else(|| "WinDeployKit".to_string())
}

fn show_main(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    {
        // Back in the Dock while the window is visible.
        let _ = app.set_activation_policy(tauri::ActivationPolicy::Regular);
    }
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn hide_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.hide();
    }
    #[cfg(target_os = "macos")]
    {
        // Menu-bar only: no Dock icon while it runs in the background.
        let _ = app.set_activation_policy(tauri::ActivationPolicy::Accessory);
    }
}

/// Tray "Quit": the webview runs its exit path (lib/tray.ts calls app_exit); if it
/// has not within the grace period, exit anyway.
fn request_quit(app: &AppHandle) {
    let _ = app.emit("tray://action", serde_json::json!({ "action": "quit" }));
    let handle = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(QUIT_GRACE_MS));
        handle.exit(0);
    });
}

/// Tray image, embedded so it works inside the .app / installer without a resource
/// lookup: the app icon's hexagon as an outline with a deploy arrow, flat black on
/// transparency (regenerate with scripts/make-tray-icons.py). macOS uses the 44 px
/// copy as a template image so the system recolours it for light and dark menu
/// bars; Windows uses the 32 px copy in the notification area.
fn tray_icon() -> Option<tauri::image::Image<'static>> {
    #[cfg(target_os = "macos")]
    let bytes: &[u8] = include_bytes!("../icons/tray-template@2x.png");
    #[cfg(not(target_os = "macos"))]
    let bytes: &[u8] = include_bytes!("../icons/tray-windows.png");
    match tauri::image::Image::from_bytes(bytes) {
        Ok(img) => Some(img.to_owned()),
        Err(e) => {
            tracing::warn!("tray icon could not be decoded: {e}");
            None
        }
    }
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

            let prefs = Arc::new(WindowPrefs { close_to_tray: AtomicBool::new(true) });
            app.manage(Arc::clone(&prefs));

            // Tray / menu-bar icon: Open and Quit, like the other kits. Quit is forwarded
            // to the webview as `tray://action` so one exit path serves menu and tray.
            let name = product_name(&handle);
            let open = MenuItem::with_id(app, "open", format!("Open {name}"), true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", format!("Quit {name}"), true, None::<&str>)?;
            let sep = PredefinedMenuItem::separator(app)?;
            let menu = Menu::with_items(app, &[&open, &sep, &quit])?;
            let mut tray = TrayIconBuilder::with_id(TRAY_ID)
                .tooltip(&name)
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "open" => show_main(app),
                    "quit" => request_quit(app),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        show_main(tray.app_handle());
                    }
                });
            if let Some(icon) = tray_icon() {
                tray = tray.icon(icon).icon_as_template(cfg!(target_os = "macos"));
            }
            tray.build(app)?;

            // The close button hides to the tray unless the user turned that off.
            if let Some(win) = app.get_webview_window("main") {
                let prefs = Arc::clone(&prefs);
                let handle = handle.clone();
                win.on_window_event(move |event| {
                    if let WindowEvent::CloseRequested { api, .. } = event {
                        if prefs.close_to_tray.load(Ordering::SeqCst) {
                            api.prevent_close();
                            hide_main(&handle);
                        }
                    }
                });
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            app_exit,
            sidecar_invoke,
            sidecar_restart,
            sidecar_status,
            check_pwsh_prerequisite_cmd,
            harvest_acer_sccm_urls,
            set_close_to_tray,
            set_tray_tooltip
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
