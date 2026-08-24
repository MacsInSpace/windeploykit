import { homeDir, join } from "@tauri-apps/api/path";
import { exists, mkdir } from "@tauri-apps/plugin-fs";

import { sidecar } from "./ipc";
import { getSetting } from "./settings";
import { SETTING_DOWNLOAD_DIR, SETTING_IMAGE_LIBRARY_DIR } from "./downloadSettings";
import { getSystemDownloadsDir } from "./downloadPath";

// The "ISO & driver root" - where ISOs, driver packs, and imageable WIMs are
// stored and served from. Mirrors sidecar/lib/AppPaths.ps1 (Get-AppImageLibraryPaths)
// and the Deploy$ shape a deploy client expects, so the laptop can serve it
// directly over SMB/HTTP:
//
//   <root>/iso/<name>.iso
//   <root>/Drivers/<Make>/<Model>/    (MDT-style publish/search convention)
//   <root>/WIMs/<name>.wim
//   <root>/.incoming/<guid>/          (aria2 staging)
//
// See docs/core/app-data/AGENT_NOTES_APP_DATA_LAYOUT.md and docs/plugins/netboot (Deploy$ SMB payload notes).

// Product slug - the same folder name the sidecar uses (Get-AppImageLibraryDefaultRoot).
const APP_ROOT_NAME = "windeploykit";

function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/**
 * Cheap, dependency-free macOS check (we have no @tauri-apps/plugin-os). The
 * WebView reports "MacIntel"/"Mac" on macOS. Only used to pick a default folder,
 * which the technician can always override, so a heuristic is acceptable.
 */
function isMacOS(): boolean {
  if (typeof navigator === "undefined") return false;
  const id = `${navigator.platform || ""} ${navigator.userAgent || ""}`;
  return /\bmac/i.test(id);
}

export interface ImageLibraryPaths {
  root: string;
  isoDir: string;
  driversDir: string;
  wimsDir: string;
  incomingDir: string;
}

/**
 * Resolved ISO & driver root. Explicit override wins; otherwise it follows the
 * main Downloads location under a "windeploykit" subfolder. The
 * imaging library is global (not per-site), so the site subfolder option is
 * intentionally ignored here.
 */
export async function getImageLibraryRoot(): Promise<string> {
  const override = String(getSetting(SETTING_IMAGE_LIBRARY_DIR)).trim();
  if (override) return override;

  // macOS: ~/Downloads (and ~/Desktop, ~/Documents) are TCC-protected, so the SMB
  // daemon can't serve the Deploy$ share from there - WinPE fails with "network
  // name not found". A custom Settings -> Downloads location outside those folders
  // is followed (Craig, 2026-08-18); only TCC-protected (or unset) bases divert to
  // ~/Public (Apple's sharing folder, not TCC-gated). Mirrors the TCC list in
  // sidecar/lib/AppPaths.ps1 (Get-AppMacOsTccProtectedRoots).
  if (isMacOS()) {
    try {
      const home = await homeDir();
      if (home) {
        const customBase = String(getSetting(SETTING_DOWNLOAD_DIR)).trim();
        if (customBase && !isMacTccProtectedPath(customBase, home)) {
          return join(customBase, APP_ROOT_NAME);
        }
        return join(home, "Public", APP_ROOT_NAME);
      }
    } catch {
      // fall through to the Downloads-based default
    }
  }

  const downloadBase =
    String(getSetting(SETTING_DOWNLOAD_DIR)).trim() || (await getSystemDownloadsDir());
  if (!downloadBase) return "";
  return join(downloadBase, APP_ROOT_NAME);
}

/** Mirrors Get-AppMacOsTccProtectedRoots in sidecar/lib/AppPaths.ps1. */
function isMacTccProtectedPath(path: string, home: string): boolean {
  const norm = (p: string) => p.replace(/\/+$/, "");
  const target = norm(path);
  const base = norm(home);
  for (const name of ["Downloads", "Desktop", "Documents"]) {
    const protectedBase = `${base}/${name}`;
    if (target === protectedBase || target.startsWith(`${protectedBase}/`)) return true;
  }
  return false;
}

export async function getImageLibraryPaths(): Promise<ImageLibraryPaths | null> {
  const root = await getImageLibraryRoot();
  if (!root) return null;
  return {
    root,
    isoDir: await join(root, "iso"),
    driversDir: await join(root, "Drivers"),
    wimsDir: await join(root, "WIMs"),
    incomingDir: await join(root, ".incoming"),
  };
}

/** Sanitise a device model into a single safe folder name (mirrors the sidecar). */
export function imageDriverModelFolderName(model: string): string {
  // Illegal on Windows: <>:"/\|?* and control chars; also strip separators.
  const cleaned = model
    .trim()
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_")
    .trim();
  return cleaned;
}

/**
 * Driver folder for a device: <root>/Drivers/<Make>/<Model>/ - the MDT-style
 * publish/search convention. Make omitted -> legacy flat <root>/Drivers/<Model>/
 * (a -Recurse -Depth 1 cache search finds both).
 */
export async function getImageDriverModelDir(model: string, make?: string): Promise<string | null> {
  const paths = await getImageLibraryPaths();
  if (!paths) return null;
  const folder = imageDriverModelFolderName(model);
  if (!folder) return null;
  const makeFolder = make ? imageDriverModelFolderName(make) : "";
  if (makeFolder) return join(paths.driversDir, makeFolder, folder);
  return join(paths.driversDir, folder);
}

export async function ensureDir(dir: string): Promise<void> {
  if (!dir || !isTauri()) return;
  try {
    await mkdir(dir, { recursive: true });
  } catch (err) {
    try {
      if (await exists(dir)) return;
    } catch {
      // fall through to rethrow
    }
    throw err;
  }
}

/** Human-readable preview for Settings (does not create directories). */
export async function formatImageLibraryRootPreview(): Promise<string> {
  const root = await getImageLibraryRoot();
  return root || "(default)/WinDeployKit";
}

export interface FreeSpaceInfo {
  ok: boolean;
  path: string;
  freeBytes: number | null;
  totalBytes: number | null;
}

/** Free/total bytes on the volume backing the image library root (pre-flight). */
export async function getImageLibraryFreeSpace(): Promise<FreeSpaceInfo | null> {
  if (!isTauri()) return null;
  const root = await getImageLibraryRoot();
  try {
    return await sidecar.invoke<FreeSpaceInfo>("GetPathFreeSpace", {
      path: root || undefined,
      ...(root ? { imageLibraryRoot: root } : {}),
    });
  } catch {
    return null;
  }
}

/** Human-readable byte size, e.g. "12.4 GB". */
export function formatBytes(bytes: number | null | undefined): string {
  if (bytes == null || !Number.isFinite(bytes)) return "-";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i += 1;
  }
  return `${value.toFixed(value >= 100 || i === 0 ? 0 : 1)} ${units[i]}`;
}

/**
 * Tell the sidecar the current ISO & driver root so promote, import, Caddy
 * routes, and the SMB share all key off the same place. Best-effort; safe to
 * call repeatedly (startup + whenever the setting changes).
 */
export async function pushImageLibraryRoot(): Promise<string | undefined> {
  if (!isTauri()) return undefined;
  const root = await getImageLibraryRoot();
  if (!root) return undefined;
  try {
    await sidecar.invoke("SetImageLibraryRoot", { imageLibraryRoot: root });
  } catch {
    // Non-fatal: aria2/pxe calls also carry imageLibraryRoot as a param.
  }
  return root;
}
