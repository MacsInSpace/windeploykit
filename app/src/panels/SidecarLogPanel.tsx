/**
 * Sidecar Log - what the PowerShell sidecar wrote to stderr, live.
 *
 * The Rust host forwards every stderr line as a "sidecar://log" event and
 * nowhere else (not the dev terminal), so until this panel existed nothing the
 * sidecar said was visible in the app. That made "No LAN IP" and "vault
 * unavailable" undiagnosable from inside it.
 *
 * Live-only: lines arrive from the moment the app is open. There is no history
 * command yet, so a restart empties it.
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { PanelShell } from "../components/PanelShell";
import { sidecar } from "../lib/ipc";
import { isTauri } from "../lib/tauriEnv";
import { useConsoleActions, type ConsoleNodeActions } from "../state/consoleActions";

const MAX_LINES = 2000;

export function SidecarLogPanel() {
  const [lines, setLines] = useState<string[]>([]);
  const [paused, setPaused] = useState(false);
  const [filter, setFilter] = useState("");
  const bottomRef = useRef<HTMLDivElement>(null);
  const pausedRef = useRef(false);
  pausedRef.current = paused;

  useEffect(() => {
    if (!isTauri()) return;
    let live = true;
    let unlisten: (() => void) | undefined;
    void sidecar
      .onLog((line) => {
        if (!live || pausedRef.current) return;
        setLines((prev) => {
          const next = prev.length >= MAX_LINES ? prev.slice(prev.length - MAX_LINES + 1) : prev.slice();
          next.push(line);
          return next;
        });
      })
      .then((fn) => {
        unlisten = fn;
      });
    return () => {
      live = false;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    if (!paused) bottomRef.current?.scrollIntoView({ block: "end" });
  }, [lines, paused]);

  const clear = useCallback(() => setLines([]), []);
  const togglePause = useCallback(() => setPaused((p) => !p), []);

  const shown = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return q ? lines.filter((l) => l.toLowerCase().includes(q)) : lines;
  }, [lines, filter]);

  const errors = useMemo(() => lines.filter((l) => /error|fail|unavailable|exception/i.test(l)).length, [lines]);

  const consoleActions = useMemo<ConsoleNodeActions>(
    () => ({
      items: [
        { label: paused ? "Resume" : "Pause", onSelect: togglePause },
        { label: "Clear", disabled: lines.length === 0, onSelect: clear },
      ],
      status: `${lines.length} line(s)${errors ? `, ${errors} flagged` : ""}${paused ? " - paused" : ""}`,
    }),
    [paused, togglePause, lines.length, errors, clear],
  );
  useConsoleActions(consoleActions);

  return (
    <PanelShell
      title="Sidecar Log"
      subtitle={<span>{shown.length === lines.length ? `${lines.length} lines` : `${shown.length} of ${lines.length}`}</span>}
      details={[
        { label: "Source", value: "sidecar stderr, live" },
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
          {paused && (
            <span className="badge badge-warn" title="New lines are being dropped while paused">
              PAUSED
            </span>
          )}
        </div>
        <div className="mono min-h-0 flex-1 overflow-auto px-3 py-2 text-[10.5px] leading-[1.5]" style={{ color: "var(--text2)" }}>
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
