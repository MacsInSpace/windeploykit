//! Acer SCCM catalog harvest via a hidden app webview.
//!
//! Acer's discovery pages (www.acer.com/sccm → community.acer.com KB) sit behind
//! fingerprint-level bot mitigation: curl is tarpitted or served a Cloudflare JS
//! challenge from ANY network, while a real browser engine passes (see
//! docs/plugins/netboot/AGENT_NOTES_PXE_DRIVERS.md §12). So the app loads the KB in a
//! hidden webview and harvests the `global-download.acer.com` pack links after the page
//! renders. Supply-side only — one technician machine refreshing a catalog, never fleet
//! clients scraping.
//!
//! Data path back from the (remote, untrusted) page: the injected script navigates to
//! `https://dk-harvest.invalid/#<base64 urls>`, which `on_navigation` intercepts and
//! cancels — the remote page is never granted Tauri IPC access, and the sidecar
//! re-validates every URL before the catalog cache is touched.

use std::sync::{Arc, Mutex};

use base64::Engine;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

/// Runs on every document load in the harvest window (Cloudflare interstitial included —
/// it simply finds no links there and keeps polling until the real article renders).
const HARVEST_SCRIPT: &str = r#"
(function () {
  if (window.__dkAcerHarvest) { return; }
  window.__dkAcerHarvest = true;
  var last = -1;
  var stable = 0;
  var timer = setInterval(function () {
    try {
      var links = document.querySelectorAll('a[href*="global-download.acer.com"]');
      var seen = {};
      var urls = [];
      for (var i = 0; i < links.length; i++) {
        var h = links[i].href;
        if (h && !seen[h]) { seen[h] = 1; urls.push(h); }
      }
      // Wait until the count is non-zero and stable for two ticks — the KB renders its
      // accordion content after DOMContentLoaded.
      if (urls.length > 0 && urls.length === last) { stable += 1; } else { stable = 0; }
      last = urls.length;
      if (urls.length > 0 && stable >= 2) {
        clearInterval(timer);
        location.href = 'https://dk-harvest.invalid/#' + btoa(urls.join('\n'));
      }
    } catch (e) { /* keep polling */ }
  }, 700);
})();
"#;

#[tauri::command]
pub async fn harvest_acer_sccm_urls(
    app: AppHandle,
    url: String,
    timeout_secs: Option<u64>,
    visible: Option<bool>,
) -> Result<Vec<String>, String> {
    let parsed: tauri::Url = url.parse().map_err(|e| format!("invalid harvest url: {e}"))?;
    if parsed.scheme() != "https" {
        return Err("harvest url must be https".into());
    }

    let label = format!("acer-harvest-{}", chrono::Utc::now().timestamp_millis());
    let (tx, rx) = tokio::sync::oneshot::channel::<Vec<String>>();
    let tx = Arc::new(Mutex::new(Some(tx)));

    // Window creation must happen on the main thread (macOS); hand the build result back
    // over a channel so a builder error still surfaces to the caller.
    let (built_tx, built_rx) = std::sync::mpsc::channel::<Result<(), String>>();
    {
        let app = app.clone();
        let label = label.clone();
        let tx_nav = tx.clone();
        let show = visible.unwrap_or(false);
        app.clone()
            .run_on_main_thread(move || {
                let result = WebviewWindowBuilder::new(&app, &label, WebviewUrl::External(parsed))
                    .title("Refreshing Acer driver catalog… (closes automatically)")
                    .inner_size(980.0, 720.0)
                    .center()
                    .visible(show)
                    .initialization_script(HARVEST_SCRIPT)
                    .on_navigation(move |nav_url| {
                        if nav_url.host_str() == Some("dk-harvest.invalid") {
                            let urls = nav_url
                                .fragment()
                                .and_then(|frag| {
                                    base64::engine::general_purpose::STANDARD.decode(frag).ok()
                                })
                                .and_then(|bytes| String::from_utf8(bytes).ok())
                                .map(|text| {
                                    text.lines()
                                        .map(|line| line.trim().to_string())
                                        .filter(|line| !line.is_empty())
                                        .collect::<Vec<_>>()
                                })
                                .unwrap_or_default();
                            if let Some(sender) = tx_nav.lock().unwrap().take() {
                                let _ = sender.send(urls);
                            }
                            return false; // never actually navigate to the sentinel host
                        }
                        true
                    })
                    .build()
                    .map(|_| ())
                    .map_err(|e| e.to_string());
                let _ = built_tx.send(result);
            })
            .map_err(|e| e.to_string())?;
    }
    built_rx
        .recv_timeout(std::time::Duration::from_secs(10))
        .map_err(|_| "harvest window build did not report back".to_string())??;

    let timeout = std::time::Duration::from_secs(timeout_secs.unwrap_or(90).clamp(15, 300));
    let outcome = tokio::time::timeout(timeout, rx).await;

    if let Some(window) = app.get_webview_window(&label) {
        let _ = window.close();
    }

    match outcome {
        Ok(Ok(urls)) if !urls.is_empty() => Ok(urls),
        Ok(Ok(_)) => Err("harvest reported no URLs".into()),
        Ok(Err(_)) => Err("harvest window closed before reporting".into()),
        Err(_) => Err(format!(
            "harvest timed out after {}s — the page or its bot challenge did not finish rendering (try again; hidden windows are throttled on macOS, so keep visible: true)",
            timeout.as_secs()
        )),
    }
}
