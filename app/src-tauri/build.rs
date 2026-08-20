fn main() {
    // Windows: the PowerShell sidecar is frequently blocked for non-elevated
    // launches on locked-down machines (AppLocker, minimal PATH), and the
    // deployment services need to bind privileged ports and manage shares
    // anyway — so the app ships requestedExecutionLevel=requireAdministrator
    // and UAC elevation happens automatically.
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "windows" {
        let mut windows = tauri_build::WindowsAttributes::new();
        windows = windows.app_manifest(include_str!("windows-app.manifest"));
        let attrs = tauri_build::Attributes::new().windows_attributes(windows);
        tauri_build::try_build(attrs).expect("failed to run build script");
    } else {
        tauri_build::build();
    }
}
