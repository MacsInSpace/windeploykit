// Thin, typed wrapper around the Tauri commands exposed by src-tauri/src/sidecar.rs.
// The Rust side handles process lifecycle, request/response correlation, and event forwarding.
// This file exists so React components can call:
//   const rows = await sidecar.invoke("GetPxeBootPluginStatus");
// and stay both ergonomic and type-safe.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

import type {
  SidecarCommand,
  SidecarEvent,
  SidecarErrorCode,
} from "./types";
import { isTauri } from "./tauriEnv";

const SIDECAR_INVOKE_CMD = "sidecar_invoke";
const SIDECAR_RESTART_CMD = "sidecar_restart";
const SIDECAR_STATUS_CMD = "sidecar_status";
const CHECK_PWSH_PREREQUISITE_CMD = "check_pwsh_prerequisite_cmd";
const SIDECAR_EVENT_CHANNEL = "sidecar://event";
const SIDECAR_LOG_CHANNEL = "sidecar://log";

export class SidecarError extends Error {
  readonly code: SidecarErrorCode;
  readonly cmd: SidecarCommand;
  constructor(cmd: SidecarCommand, message: string, code: SidecarErrorCode) {
    super(`[${cmd}] ${message}`);
    this.name = "SidecarError";
    this.code = code;
    this.cmd = cmd;
  }
}

// Mirrors the `#[serde(tag = "kind", content = "details")]` shape of
// `SidecarError` in src-tauri/src/sidecar.rs. Tauri serializes a returned
// `Err(SidecarError)` through this enum, so the JS-side error payload is
// NOT `{ message, code }` -- it's `{ kind, details? }`.
type RustSidecarError =
  | { kind: "NotRunning" }
  | { kind: "Io"; details: string }
  | { kind: "Timeout"; details: number }
  | { kind: "Remote"; details: { message: string; code: string } }
  | { kind: "BadResponse"; details: string };

function toSidecarError(cmd: SidecarCommand, err: unknown): SidecarError {
  if (typeof err === "string") {
    return new SidecarError(cmd, err, "UNKNOWN");
  }
  if (err && typeof err === "object" && "kind" in (err as object)) {
    const re = err as RustSidecarError;
    switch (re.kind) {
      case "NotRunning":
        return new SidecarError(cmd, "Sidecar is not running", "UNKNOWN");
      case "Io":
        return new SidecarError(cmd, `IO error: ${re.details}`, "UNKNOWN");
      case "Timeout":
        return new SidecarError(
          cmd,
          `Timed out after ${re.details}s`,
          "UNKNOWN",
        );
      case "Remote":
        return new SidecarError(
          cmd,
          re.details?.message ?? "Sidecar returned an error",
          (re.details?.code as SidecarErrorCode) ?? "UNKNOWN",
        );
      case "BadResponse":
        return new SidecarError(cmd, `Bad response: ${re.details}`, "UNKNOWN");
    }
  }
  if (err && typeof err === "object" && "message" in (err as object)) {
    const m = String((err as { message: unknown }).message);
    return new SidecarError(cmd, m, "UNKNOWN");
  }
  return new SidecarError(
    cmd,
    `Sidecar invocation failed (${typeof err})`,
    "UNKNOWN",
  );
}

/**
 * Send a command to the PowerShell sidecar and wait for its response.
 *
 * The Rust process holds a long-lived pwsh child and correlates requests by id.
 * Errors from the sidecar are raised as {@link SidecarError} so React panels can
 * branch on `err.code` (e.g. SESSION_NOT_ESTABLISHED triggers the reconnect banner).
 */
export async function invokeSidecar<T = unknown, P = unknown>(
  cmd: SidecarCommand,
  params?: P,
): Promise<T> {
  try {
    return await invoke<T>(SIDECAR_INVOKE_CMD, {
      cmd,
      params: params ?? {},
    });
  } catch (err) {
    throw toSidecarError(cmd, err);
  }
}

export async function restartSidecar(
  spawnEnv?: Record<string, string>,
): Promise<void> {
  await invoke<void>(SIDECAR_RESTART_CMD, { spawnEnv: spawnEnv ?? null });
}

export interface SidecarStatus {
  running: boolean;
  ready: boolean;
  pid?: number;
  startedAt?: string;
  lastError?: string;
}

export async function getSidecarStatus(): Promise<SidecarStatus> {
  return await invoke<SidecarStatus>(SIDECAR_STATUS_CMD);
}

export interface PwshPrerequisite {
  available: boolean;
  path?: string;
  platform: string;
  installCommand?: string;
  releasesUrl: string;
}

export async function checkPwshPrerequisite(): Promise<PwshPrerequisite> {
  return await invoke<PwshPrerequisite>(CHECK_PWSH_PREREQUISITE_CMD);
}

export type SidecarEventHandler = (ev: SidecarEvent) => void;
export type SidecarLogHandler = (line: string) => void;

export function onSidecarEvent(handler: SidecarEventHandler): Promise<UnlistenFn> {
  return listen<SidecarEvent>(SIDECAR_EVENT_CHANNEL, (e) => handler(e.payload));
}

export function onSidecarLog(handler: SidecarLogHandler): Promise<UnlistenFn> {
  return listen<string>(SIDECAR_LOG_CHANNEL, (e) => handler(e.payload));
}

// -- tray / window (Rust host; no-ops outside Tauri) --------------------------------

export type TrayAction = "open" | "quit" | string;

/** Push the close-to-tray preference to the host (lib/tray.ts does this at boot and on change). */
export async function setCloseToTray(enabled: boolean): Promise<void> {
  if (!isTauri()) return;
  await invoke<void>("set_close_to_tray", { enabled });
}

/** Tray tooltip: the product name, with the PXE server URL while it runs. */
export async function setTrayTooltip(text: string): Promise<void> {
  if (!isTauri()) return;
  await invoke<void>("set_tray_tooltip", { text });
}

/** Real exit (bypasses close-to-tray). The host stops the sidecar on the way out. */
export async function appExit(): Promise<void> {
  if (!isTauri()) {
    window.close();
    return;
  }
  await invoke<void>("app_exit");
}

/** The tray menu's verbs reach the webview here (Open is handled by the host itself). */
export function onTrayAction(handler: (action: TrayAction) => void): Promise<UnlistenFn> {
  if (!isTauri()) return Promise.resolve(() => undefined);
  return listen<{ action: string }>("tray://action", (e) => handler(e.payload?.action ?? ""));
}

export const sidecar = {
  invoke: invokeSidecar,
  restart: restartSidecar,
  status: getSidecarStatus,
  checkPwsh: checkPwshPrerequisite,
  onEvent: onSidecarEvent,
  onLog: onSidecarLog,
};
