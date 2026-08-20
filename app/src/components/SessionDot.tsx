import { normalizeSessionState } from "../lib/sessionStatus";
import type { SessionState } from "../lib/types";

interface SessionDotProps {
  label: string;
  state: SessionState;
  message?: string;
}

function dotClass(state: SessionState | string): string {
  switch (state) {
    case "ok": // sidecar raw value if normalization was skipped
    case "connected":
      return "dot-status dot-ok";
    case "connecting":
      return "dot-status dot-pending";
    case "disconnected":
    case "error":
      return "dot-status dot-err";
    case "skipped":
    case "unknown":
    default:
      return "dot-status dot-dim";
  }
}

export function SessionDot({ label, state, message }: SessionDotProps) {
  const display = normalizeSessionState(state);
  const title = message ? `${label} — ${display} (${message})` : `${label} — ${display}`;
  return (
    <div className="flex items-center gap-[6px]" title={title}>
      <span className={dotClass(display)} aria-hidden />
      <span className="mono text-[10px]" style={{ color: "var(--text3)", letterSpacing: "0.1em" }}>
        {label}
      </span>
    </div>
  );
}
