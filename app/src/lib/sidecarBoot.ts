/**
 * Sidecar lifecycle - the one place the app starts the PowerShell sidecar.
 *
 * The Rust host deliberately does not spawn it (lib.rs: "deferred until the JS
 * shell calls sidecar_restart with diagnostics env from saved Settings"). In
 * the upstream app the sign-in flow made that call; that flow was removed in
 * the extraction and nothing replaced it, so until 2026-08-21 this app never
 * had a running sidecar and every panel starved behind "Sidecar is not
 * running" - which the Netboot panel then reported as "No LAN IP".
 *
 * Singleton on purpose: React StrictMode runs mount effects twice, and two
 * sidecar_restart calls would kill the first child to spawn a second.
 */
import { useSyncExternalStore } from "react";

import { sidecar } from "./ipc";
import { pushImageLibraryRoot } from "./imageLibrary";
import { buildRuntimeConfigForSidecar, buildSidecarSpawnEnv } from "./runtimeConfig";
import { isTauri } from "./tauriEnv";

export type SidecarLifecycle =
  | "idle"
  | "checking"
  | "missing-pwsh"
  | "starting"
  | "ready"
  | "stopped"
  | "error";

export interface SidecarBootState {
  lifecycle: SidecarLifecycle;
  /** Human message for the error/missing states. */
  detail?: string;
  /** Install hint when PowerShell 7 is absent. */
  installCommand?: string;
}

let state: SidecarBootState = { lifecycle: "idle" };
const listeners = new Set<() => void>();
let bootPromise: Promise<void> | null = null;
let eventsWired = false;

function set(next: SidecarBootState) {
  state = next;
  for (const l of listeners) l();
}

export function getSidecarBootState(): SidecarBootState {
  return state;
}

export function useSidecarBootState(): SidecarBootState {
  return useSyncExternalStore(
    (fn) => {
      listeners.add(fn);
      return () => {
        listeners.delete(fn);
      };
    },
    getSidecarBootState,
    getSidecarBootState,
  );
}

/** After the sidecar announces ready: settings it only learns from us. */
async function onReady() {
  set({ lifecycle: "ready" });
  try {
    await sidecar.invoke("ApplyRuntimeConfig", buildRuntimeConfigForSidecar());
  } catch {
    /* diagnostics flags only - never block on them */
  }
  // The image library root is pushed at app start too, but that push is lost
  // when it races the spawn. Repeat it now that someone is listening.
  await pushImageLibraryRoot();
}

async function wireEvents() {
  if (eventsWired) return;
  eventsWired = true;
  await sidecar.onEvent((ev) => {
    if (ev.event === "ready") void onReady();
    else if (ev.event === "exited") set({ lifecycle: "stopped", detail: "The sidecar process exited." });
    else if (ev.event === "error") {
      const msg = (ev.data as { message?: string } | undefined)?.message;
      set({ lifecycle: "error", detail: msg ?? "The sidecar reported an error." });
    }
  });
}

/** Start the sidecar if it is not already running. Safe to call repeatedly. */
export function ensureSidecarStarted(): Promise<void> {
  if (!isTauri()) return Promise.resolve();
  if (bootPromise) return bootPromise;
  bootPromise = (async () => {
    set({ lifecycle: "checking" });
    await wireEvents();

    const status = await sidecar.status().catch(() => null);
    if (status?.running) {
      if (status.ready) await onReady();
      else set({ lifecycle: "starting" });
      return;
    }

    const pwsh = await sidecar.checkPwsh().catch(() => null);
    if (pwsh && !pwsh.available) {
      set({
        lifecycle: "missing-pwsh",
        detail: "PowerShell 7 (pwsh) was not found. Install it, then restart the app.",
        installCommand: pwsh.installCommand,
      });
      return;
    }

    set({ lifecycle: "starting" });
    try {
      await sidecar.restart(buildSidecarSpawnEnv());
      // The 'ready' event moves us on; if it never comes, status() will say so
      // on the next restartSidecarNow().
    } catch (e) {
      set({ lifecycle: "error", detail: e instanceof Error ? e.message : String(e) });
    }
  })().finally(() => {
    // Allow a later explicit restart after an error; a success keeps the
    // promise so repeat callers do not respawn.
    if (state.lifecycle === "error" || state.lifecycle === "missing-pwsh") bootPromise = null;
  });
  return bootPromise;
}

/** Explicit restart from the UI (status-bar badge, Sidecar Log verb). */
export async function restartSidecarNow(): Promise<void> {
  if (!isTauri()) return;
  set({ lifecycle: "starting" });
  try {
    await sidecar.restart(buildSidecarSpawnEnv());
  } catch (e) {
    set({ lifecycle: "error", detail: e instanceof Error ? e.message : String(e) });
  }
}
