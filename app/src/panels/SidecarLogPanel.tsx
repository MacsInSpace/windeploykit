/**
 * Sidecar Log - what the PowerShell sidecar wrote to stderr, live.
 *
 * The Rust host forwards every stderr line as a "sidecar://log" event and
 * nowhere else (not the dev terminal), so until this panel existed nothing the
 * sidecar said was visible in the app. That made "No LAN IP" and "vault
 * unavailable" undiagnosable from inside it.
 *
 * History is collected from app start by lib/sidecarLogBuffer (not from when this
 * panel mounts), so the boot lines are here when you come looking. A sidecar
 * restart keeps the buffer; Clear empties it.
 */
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";

import { PanelShell } from "../components/PanelShell";
import { toast } from "../state/toastStore";
import { isTauri } from "../lib/tauriEnv";
import {
  clearSidecarLogBuffer,
  getSidecarLogSnapshot,
  subscribeSidecarLog,
} from "../lib/sidecarLogBuffer";
import { restartSidecarNow, useSidecarBootState } from "../lib/sidecarBoot";
import { useConsoleActions, type ConsoleNodeActions } from "../state/consoleActions";

const MAX_LINES = 2000;

export function SidecarLogPanel() {
  // History lives outside the panel, so opening it shows what the sidecar already
  // said (boot, vault, LAN) rather than starting from nothing.
  const buffered = useSyncExternalStore(subscribeSidecarLog, getSidecarLogSnapshot, getSidecarLogSnapshot);
  // Pause freezes what is shown without dropping lines from the buffer.
  const [frozen, setFrozen] = useState<string[] | null>(null);
  const lines = frozen ?? buffered;
  const boot = useSidecarBootState();
  const [paused, setPaused] = useState(false);
  const [filter, setFilter] = useState("");
  const bottomRef = useRef<HTMLDivElement>(null);
  const pausedRef = useRef(false);
  pausedRef.current = paused;

  useEffect(() => {
    if (!paused) bottomRef.current?.scrollIntoView({ block: "end" });
  }, [lines, paused]);

  const clear = useCallback(() => {
    clearSidecarLogBuffer();
    setFrozen(null);
  }, []);
  const togglePause = useCallback(
    () =>
      setPaused((p) => {
        // Freeze the current view rather than discarding what arrives while paused.
        setFrozen(p ? null : getSidecarLogSnapshot());
        return !p;
      }),
    [],
  );

  const shown = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return q ? lines.filter((l) => l.toLowerCase().includes(q)) : lines;
  }, [lines, filter]);

  const copyShown = useCallback(async () => {
    // Selecting text in a webview panel is fiddly at the best of times, and the log is the
    // one thing people need to paste elsewhere (Craig, 2026-08-22: "I cant copy paste from
    // Sidecar"). Copies exactly what is on screen, filter included.
    const text = shown.join("\n");
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      toast.success("Sidecar log", `${shown.length} line(s) copied.`);
    } catch (e) {
      toast.error("Sidecar log", e instanceof Error ? e.message : String(e));
    }
  }, [shown]);

  const errors = useMemo(() => lines.filter((l) => /error|fail|unavailable|exception/i.test(l)).length, [lines]);

  const consoleActions = useMemo<ConsoleNodeActions>(
    () => ({
      items: [
        { label: paused ? "Resume" : "Pause", onSelect: togglePause },
        { label: "Copy", disabled: shown.length === 0, onSelect: () => void copyShown() },
        { label: "Clear", disabled: lines.length === 0, onSelect: clear },
        { label: "-" },
        { label: "Restart Sidecar", disabled: !isTauri(), onSelect: () => void restartSidecarNow() },
      ],
      status: `${lines.length} line(s)${errors ? `, ${errors} flagged` : ""}${paused ? " - paused" : ""}`,
    }),
    [paused, togglePause, lines.length, errors, clear, shown.length, copyShown],
  );
  useConsoleActions(consoleActions);

  return (
    <PanelShell
      title="Sidecar Log"
      subtitle={<span>{shown.length === lines.length ? `${lines.length} lines` : `${shown.length} of ${lines.length}`}</span>}
      details={[
        { label: "Sidecar", value: boot.lifecycle + (boot.detail ? ` - ${boot.detail}` : ""), tone: boot.lifecycle === "ready" || boot.lifecycle === "starting" || boot.lifecycle === "checking" ? "normal" : "bad" },
        { label: "Source", value: "sidecar stderr, from app start" },
        { label: "Buffer", value: `last ${MAX_LINES} lines` },
        errors > 0 && { label: "Flagged", value: `${errors} line(s)`, tone: "warn" },
        !isTauri() && { label: "Note", value: "no sidecar outside the desktop app" },
      ]}
      bodyClassName="overflow-hidden"
    >
      <div className="flex h-full min-h-0 flex-col">
        <div className="flex items-center gap-2 border-b px-3 py-1.5" style={{ borderColor: "var(--border)" }}>
          <div className="input-box mono flex-1 text-[11px]">
            <input
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              placeholder="Filter lines..."
              spellCheck={false}
            />
          </div>
          <button
            type="button"
            className="btn px-2 py-0.5 text-[10px]"
            disabled={shown.length === 0}
            title="Copy the lines shown (respects the filter)"
            onClick={() => void copyShown()}
          >
            Copy
          </button>
          {paused && (
            <span className="badge badge-warn" title="The view is frozen; lines are still being collected">
              PAUSED
            </span>
          )}
        </div>
        <div
          className="mono min-h-0 flex-1 overflow-auto px-3 py-2 text-[10.5px] leading-[1.5]"
          style={{ color: "var(--text2)", userSelect: "text", WebkitUserSelect: "text", cursor: "text" }}
        >
          {shown.length === 0 ? (
            <p className="empty-state">
              {lines.length === 0 ? "Nothing from the sidecar yet." : "No lines match the filter."}
            </p>
          ) : (
            shown.map((l, i) => (
              <div
                key={i}
                className="whitespace-pre-wrap break-words"
                style={/error|fail|unavailable|exception/i.test(l) ? { color: "var(--red)" } : undefined}
              >
                {l}
              </div>
            ))
          )}
          <div ref={bottomRef} />
        </div>
      </div>
    </PanelShell>
  );
}
