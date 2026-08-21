import { downloadDir, join } from "@tauri-apps/api/path";
import { exists, mkdir } from "@tauri-apps/plugin-fs";

import { getAppState } from "../state/appStore";
import { getSetting } from "./settings";
import { SETTING_DOWNLOAD_DIR, SETTING_DOWNLOAD_SITE_SUBDIR } from "./downloadSettings";

function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/** Site id — used for the optional per-site download subfolder. */
export function getActiveSiteIdForDownloads(): string | undefined {
  const siteId = getAppState().siteProfile.siteId;
  return siteId?.trim() || undefined;
}

export async function getSystemDownloadsDir(): Promise<string> {
  if (!isTauri()) return "";
  try {
    return await downloadDir();
  } catch {
    return "";
  }
}

/** Resolved base directory before appending a file name. */
export async function getConfiguredDownloadBaseDir(siteId?: string): Promise<string> {
  const configured = String(getSetting(SETTING_DOWNLOAD_DIR)).trim();
  let base = configured || (await getSystemDownloadsDir());

  if (getSetting(SETTING_DOWNLOAD_SITE_SUBDIR)) {
    const sn = (siteId ?? getActiveSiteIdForDownloads())?.trim();
    if (sn && base) {
      base = await join(base, sn);
    }
  }

  return base;
}

export async function ensureDownloadDir(dir: string): Promise<void> {
  if (!dir || !isTauri()) return;
  try {
    // mkdir -p: creates ~/Downloads/5573 (and any missing parents) when the
    // site subfolder option is on.
    await mkdir(dir, { recursive: true });
  } catch (err) {
    // Some platforms error when the folder already exists — treat that as ok.
    try {
      if (await exists(dir)) return;
    } catch {
      // exists check failed; rethrow original mkdir error below.
    }
    throw err;
  }
}

/** Full path for a download/export file; creates parent folders when possible. */
export async function resolveDownloadFilePath(
  fileName: string,
  siteId?: string,
): Promise<string> {
  const dir = await getConfiguredDownloadBaseDir(siteId);
  if (!dir) return fileName;
  await ensureDownloadDir(dir);
  return join(dir, fileName);
}

/** `defaultPath` for Tauri save dialogs. */
export async function getSaveDialogDefaultPath(
  fileName: string,
  siteId?: string,
): Promise<string> {
  return resolveDownloadFilePath(fileName, siteId);
}

/** Human-readable preview for Settings (does not create directories). */
export async function formatConfiguredDownloadDirPreview(
  siteId?: string,
): Promise<string> {
  const dir = await getConfiguredDownloadBaseDir(siteId);
  return dir || "(system Downloads)";
}
