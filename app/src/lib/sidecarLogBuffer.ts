/**
 * Sidecar log history.
 *
 * The Rust host forwards every sidecar stderr line as an event and nowhere else.
 * The log panel used to subscribe on mount, which meant everything the sidecar
 * said before someone opened the panel was gone - including the whole boot, the
 * vault status and the LAN discovery, i.e. exactly the lines you go looking for.
 * The panel showed "Nothing from the sidecar yet" on a perfectly healthy sidecar
 * (field, 2026-08-22).
 *
 * So the subscription lives here instead: started once at boot, it keeps the last
 * MAX_LINES lines whether or not anyone is looking. The panel renders the history
 * on mount and subscribes for the rest.
 */
import { sidecar } from "./ipc";
import { isTauri } from "./tauriEnv";

const MAX_LINES = 2000;

let lines: string[] = [];
let started = false;
const listeners = new Set<() => void>();

function emit() {
  for (const fn of listeners) fn();
}

/** Begin collecting. Safe to call repeatedly; only the first call subscribes. */
export function startSidecarLogBuffer() {
  if (started || !isTauri()) return;
  started = true;
  void sidecar.onLog((line) => {
    // New array each time: useSyncExternalStore compares snapshots by identity.
    lines = lines.length >= MAX_LINES ? [...lines.slice(lines.length - MAX_LINES + 1), line] : [...lines, line];
    emit();
  });
}

export function getSidecarLogSnapshot(): string[] {
  return lines;
}

export function subscribeSidecarLog(fn: () => void): () => void {
  // A panel opened before boot finished still gets a running buffer.
  startSidecarLogBuffer();
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

export function clearSidecarLogBuffer() {
  lines = [];
  emit();
}
