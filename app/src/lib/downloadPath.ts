import { downloadDir, join } from "@tauri-apps/api/path";
import { exists, mkdir } from "@tauri-apps/plugin-fs";

import { getAppState } from "../state/appStore";
import { getSetting } from "./settings";
import { SETTING_DOWNLOAD_DIR, SETTING_DOWNLOAD_SCHOOL_SUBDIR } from "./downloadSettings";

function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/** Site id — used for the optional per-site download subfolder. */
export function getActiveSchoolNumberForDownloads(): string | undefined {
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
export async function getConfiguredDownloadBaseDir(schoolNumber?: string): Promise<string> {
  const configured = String(getSetting(SETTING_DOWNLOAD_DIR)).trim();
  let base = configured || (await getSystemDownloadsDir());

  if (getSetting(SETTING_DOWNLOAD_SCHOOL_SUBDIR)) {
    const sn = (schoolNumber ?? getActiveSchoolNumberForDownloads())?.trim();
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
    // school subfolder option is on.
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
  schoolNumber?: string,
): Promise<string> {
  const dir = await getConfiguredDownloadBaseDir(schoolNumber);
  if (!dir) return fileName;
  await ensureDownloadDir(dir);
  return join(dir, fileName);
}

/** `defaultPath` for Tauri save dialogs. */
export async function getSaveDialogDefaultPath(
  fileName: string,
  schoolNumber?: string,
): Promise<string> {
  return resolveDownloadFilePath(fileName, schoolNumber);
}

/** Human-readable preview for Settings (does not create directories). */
export async function formatConfiguredDownloadDirPreview(
  schoolNumber?: string,
): Promise<string> {
  const dir = await getConfiguredDownloadBaseDir(schoolNumber);
  return dir || "(system Downloads)";
}
