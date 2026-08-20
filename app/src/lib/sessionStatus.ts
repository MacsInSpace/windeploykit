import type { SessionState, SessionStatus } from "./types";

/** Map sidecar session vocabulary (ok/pending/failed) to UI states. */
export function normalizeSessionState(v: unknown): SessionState {
  switch (v) {
    case "ok":
      return "connected";
    case "pending":
      return "connecting";
    case "failed":
      return "error";
    case "connected":
    case "connecting":
    case "disconnected":
    case "error":
    case "skipped":
    case "unknown":
      return v;
    default:
      return "unknown";
  }
}

const SESSION_KEYS = ["http", "tftp", "smb"] as const;

/**
 * Normalize a partial or full session status blob from the sidecar
 * (`sessions` on context payload uses ok/pending/failed).
 */
export function normalizeSessionStatus(
  raw: Partial<Record<string, unknown>> | undefined,
  base?: SessionStatus,
): SessionStatus | undefined {
  if (!raw) return base;

  const next: SessionStatus = {
    http: base?.http ?? "unknown",
    tftp: base?.tftp ?? "unknown",
    smb: base?.smb ?? "unknown",
    httpMessage: base?.httpMessage,
    tftpMessage: base?.tftpMessage,
    smbMessage: base?.smbMessage,
  };

  for (const key of SESSION_KEYS) {
    if (raw[key] !== undefined) {
      next[key] = normalizeSessionState(raw[key]);
    }
  }

  const msgKeys = [
    ["httpMessage", "httpMessage"],
    ["tftpMessage", "tftpMessage"],
    ["smbMessage", "smbMessage"],
  ] as const;
  for (const [src, dest] of msgKeys) {
    if (typeof raw[src] === "string") {
      next[dest] = raw[src];
    }
  }

  return next;
}
