/**
 * Tray / menu-bar integration (Tauri host only). The Rust side owns the icon, the
 * menu and the close-to-tray window behaviour (src-tauri/src/lib.rs); this module
 * pushes the saved preference and the tooltip to it and answers the menu's Quit
 * through the normal exit path. Same shape as AdobeUpdateKit and USM, so the three
 * apps behave alike in the menu bar.
 */
import { appExit, onTrayAction, setCloseToTray, setTrayTooltip } from "./ipc";
import { getSetting, SETTING_CLOSE_TO_TRAY, subscribeSettings } from "./settings";
import { isTauri } from "./tauriEnv";
import type { PxeBootPluginStatus } from "./types";

const APP_NAME = "WinDeployKit";

let started = false;
let lastTooltip = "";

function pushCloseToTray(): void {
  void setCloseToTray(getSetting(SETTING_CLOSE_TO_TRAY)).catch(() => undefined);
}

/** Tooltip: the product name, plus the PXE server's URL while it is serving. Called
 *  from the PXE panel cache whenever a status lands, so it follows Start / Stop. */
export function pushTrayTooltip(status: PxeBootPluginStatus | null | undefined): void {
  if (!isTauri()) return;
  const url = status?.running && status.httpUrl ? status.httpUrl : null;
  const text = url ? `${APP_NAME} - PXE boot serving at ${url}` : APP_NAME;
  if (text === lastTooltip) return;
  lastTooltip = text;
  void setTrayTooltip(text).catch(() => undefined);
}

/** Real quit, the same path as File > Exit: the host stops the sidecar on the way out. */
export async function quitApp(): Promise<void> {
  await appExit();
}

/** Wire once at boot. Safe to call repeatedly. */
export function startTrayIntegration(): void {
  if (started || !isTauri()) return;
  started = true;
  pushCloseToTray();
  subscribeSettings(pushCloseToTray);
  pushTrayTooltip(null);
  void onTrayAction((action) => {
    if (action === "quit") void quitApp();
  });
}
