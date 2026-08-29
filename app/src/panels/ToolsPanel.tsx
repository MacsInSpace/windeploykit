/**
 * Tools - every third-party executable the app uses: where it comes from, what is
 * installed, whether its project has published a newer release, and the two verbs
 * that change anything: Update (one tool, one click, never automatic) and Use previous
 * (the kept copy, no network). Same shape as AdobeUpdateKit's Core Updates node.
 *
 * Runtime installs are untouched: a plug-in still installs the PINNED version on its
 * own when it needs the tool. This panel only obtains newer releases, and only when
 * asked. Sources are each tool's own project (GitHub, 7-zip.org) or our build from
 * upstream source shipped inside the app; Homebrew is never consulted.
 */
import { useCallback, useEffect, useMemo, useState } from "react";

import { ConfirmModal } from "../components/ConfirmModal";
import { PanelShell } from "../components/PanelShell";
import { useConsoleActions, type ConsoleNodeActions } from "../state/consoleActions";
import { sidecar } from "../lib/ipc";
import type { CheckToolUpdatesResult, EnsureToolsResult, ToolActionResult, ToolStatusRow, ToolsStatus } from "../lib/types";

type Busy = "load" | "check" | "ensure" | `update:${string}` | `rollback:${string}` | null;

interface Confirm {
  kind: "update" | "rollback";
  row: ToolStatusRow;
}

function formatWhen(iso: string | null | undefined): string {
  if (!iso) return "never";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString();
}

export function ToolsPanel() {
  const [status, setStatus] = useState<ToolsStatus | null>(null);
  const [busy, setBusy] = useState<Busy>(null);
  const [lines, setLines] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<Confirm | null>(null);

  const load = useCallback(async () => {
    setBusy((b) => b ?? "load");
    try {
      setStatus(await sidecar.invoke<ToolsStatus>("GetTools", {}));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy((b) => (b === "load" ? null : b));
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const checkUpdates = useCallback(async () => {
    setBusy("check");
    setError(null);
    try {
      const r = await sidecar.invoke<CheckToolUpdatesResult>("CheckToolUpdates", { force: true });
      setStatus(r.tools);
      setLines([`Checked each project at ${formatWhen(r.checkedAt)}`]);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }, []);

  const ensure = useCallback(async (ids?: string[]) => {
    setBusy("ensure");
    setError(null);
    setLines([]);
    try {
      const r = await sidecar.invoke<EnsureToolsResult>("EnsureTools", ids ? { tools: ids } : {});
      setLines(r.lines ?? []);
      setStatus(r.tools);
      if (!r.ok && r.failures?.length) {
        setError(r.failures.map((f) => `${f.tool}: ${f.message}`).join("; "));
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }, []);

  const runAction = useCallback(async (kind: "update" | "rollback", id: string) => {
    setBusy(`${kind}:${id}`);
    setError(null);
    setLines([]);
    try {
      const r = await sidecar.invoke<ToolActionResult>(kind === "update" ? "UpdateTool" : "RollbackTool", { id });
      setLines(r.lines ?? []);
      setStatus(r.tools);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }, []);

  const rows = status?.rows ?? [];
  const missing = useMemo(() => rows.filter((r) => r.downloadable && !r.present), [rows]);
  const updates = useMemo(() => rows.filter((r) => r.updatable && r.updateAvailable), [rows]);
  const present = rows.filter((r) => r.present).length;

  const consoleActions = useMemo<ConsoleNodeActions>(
    () => ({
      items: [
        {
          label: busy === "check" ? "Checking..." : "Check for updates",
          disabled: busy !== null,
          onSelect: () => void checkUpdates(),
        },
        {
          label: busy === "ensure" ? "Downloading..." : `Download missing tools${missing.length ? ` (${missing.length})` : ""}`,
          disabled: busy !== null || missing.length === 0,
          onSelect: () => void ensure(),
        },
      ],
      refresh: () => void load(),
      status: status ? `${present} of ${rows.length} present` : undefined,
    }),
    [busy, checkUpdates, ensure, load, missing.length, present, rows.length, status],
  );
  useConsoleActions(consoleActions);

  const subtitle = !status
    ? undefined
    : updates.length > 0
      ? `${updates.length} update${updates.length === 1 ? "" : "s"} available`
      : status.updateCheckedAt
        ? "Every tool is current"
        : "Not checked for updates yet";

  return (
    <>
      <PanelShell
        title="Tools"
        subtitle={subtitle}
        details={[
          { label: "Platform", value: status?.platformKey ?? "-" },
          { label: "Last update check", value: formatWhen(status?.updateCheckedAt) },
          { label: "Missing (required)", value: String(status?.missingRequired ?? 0), tone: status && status.missingRequired > 0 ? "warn" : "normal" },
        ]}
      >
        <div className="flex flex-col gap-4 px-5 py-4">
          <section>
            <div
              className="mono mb-2 text-[9px] font-medium uppercase"
              style={{ color: "var(--text3)", letterSpacing: "0.15em" }}
            >
              Third-party executables
            </div>
            <div
              className="rounded-sm px-3 py-1"
              style={{ background: "var(--surface2)", border: "1px solid var(--border)" }}
            >
              {rows.length === 0 ? (
                <div className="mono py-1 text-[11px]" style={{ color: "var(--text3)" }}>
                  {busy === "load" ? "Checking tools..." : "Tool inventory unavailable."}
                </div>
              ) : (
                rows.map((row) => {
                  const rowBusy = busy === `update:${row.id}` || busy === `rollback:${row.id}`;
                  return (
                    <div
                      key={row.id}
                      className="flex flex-wrap items-center gap-2 py-1.5"
                      style={{ borderBottom: "1px solid var(--border)" }}
                      title={row.note ?? row.path ?? undefined}
                    >
                      <div className="flex min-w-0 flex-1 flex-col gap-0.5" style={{ minWidth: 260 }}>
                        <div className="flex items-center gap-2">
                          <span className="mono text-[11.5px]" style={{ color: "var(--text)" }}>
                            {row.label}
                          </span>
                          <span
                            className="badge mono"
                            style={{ color: row.present ? "var(--green)" : row.optional ? "var(--text3)" : "var(--red)" }}
                          >
                            {row.present ? "present" : row.optional ? "optional" : "missing"}
                          </span>
                          {row.bundled ? <span className="badge badge-dim mono">bundled</span> : null}
                          {row.offline ? (
                            <span className="badge badge-dim mono" title="Needed to serve on a school LAN - obtain it before going on site">
                              needed on site
                            </span>
                          ) : null}
                          {row.updateAvailable ? (
                            <span className="badge mono" style={{ color: "var(--amber)" }}>
                              {row.kind === "prereq" ? `newer release ${row.latestVersion}` : `update ${row.latestVersion}`}
                            </span>
                          ) : null}
                        </div>
                        <div className="mono truncate text-[10px]" style={{ color: "var(--text3)" }}>
                          {row.version ? `installed ${row.version}` : "not installed"}
                          {row.pinnedVersion ? ` · pinned ${row.pinnedVersion}` : ""}
                          {row.latestVersion ? ` · latest ${row.latestVersion}` : ""}
                          {row.previousVersion ? ` · previous ${row.previousVersion} kept` : ""}
                          {" · "}
                          {row.source}
                          {row.updateCheckError ? ` · check failed: ${row.updateCheckError}` : ""}
                        </div>
                      </div>
                      <div className="flex items-center gap-1.5">
                        {row.downloadable && !row.present ? (
                          <button type="button" className="btn" disabled={busy !== null} onClick={() => void ensure([row.id])}>
                            {busy === "ensure" ? "Downloading..." : "Install"}
                          </button>
                        ) : null}
                        {row.updatable && row.updateAvailable ? (
                          <button
                            type="button"
                            className="btn btn-primary"
                            disabled={busy !== null}
                            onClick={() => setConfirm({ kind: "update", row })}
                          >
                            {rowBusy && busy?.startsWith("update:") ? "Updating..." : "Update"}
                          </button>
                        ) : null}
                        {row.previousVersion ? (
                          <button
                            type="button"
                            className="btn"
                            disabled={busy !== null}
                            onClick={() => setConfirm({ kind: "rollback", row })}
                            title={`Put ${row.previousVersion} back - the kept copy, no download`}
                          >
                            {rowBusy && busy?.startsWith("rollback:") ? "Restoring..." : "Use previous"}
                          </button>
                        ) : null}
                      </div>
                    </div>
                  );
                })
              )}
            </div>
            <div className="mt-2 text-[11px]" style={{ color: "var(--text3)" }}>
              Plug-ins install the pinned version themselves when they need a tool. Update installs
              the newest release its project has published, verified against the SHA-256 the release
              carries, and keeps the copy it replaces.
            </div>
          </section>

          {lines.length > 0 ? (
            <section>
              <div
                className="mono mb-2 text-[9px] font-medium uppercase"
                style={{ color: "var(--text3)", letterSpacing: "0.15em" }}
              >
                Output
              </div>
              <div
                className="mono max-h-48 overflow-auto rounded-sm px-3 py-2 text-[10.5px]"
                style={{ background: "var(--surface2)", border: "1px solid var(--border)", color: "var(--text2)" }}
              >
                {lines.map((line, i) => (
                  <div key={i}>{line}</div>
                ))}
              </div>
            </section>
          ) : null}

          {error ? (
            <div className="text-[11.5px]" style={{ color: "var(--red)" }}>
              {error}
            </div>
          ) : null}
        </div>
      </PanelShell>

      <ConfirmModal
        open={confirm !== null}
        title={confirm?.kind === "rollback" ? "Use the previous version" : "Update tool"}
        subtitle={confirm?.row.label}
        confirmLabel={confirm?.kind === "rollback" ? "Use previous" : "Update"}
        body={
          confirm ? (
            <div className="text-[12px]" style={{ color: "var(--text2)" }}>
              {confirm.kind === "rollback" ? (
                <>
                  Put <span className="mono">{confirm.row.previousVersion}</span> back in place of{" "}
                  <span className="mono">{confirm.row.version}</span>. The kept copy is used; nothing is downloaded.
                </>
              ) : (
                <>
                  Download <span className="mono">{confirm.row.latestVersion}</span> from{" "}
                  <span className="mono">{confirm.row.source}</span> and replace{" "}
                  <span className="mono">{confirm.row.version ?? "the installed copy"}</span>. The current
                  binary is kept so you can go back. Services using it pick up the new copy on their next start.
                </>
              )}
            </div>
          ) : null
        }
        onCancel={() => setConfirm(null)}
        onConfirm={() => {
          if (!confirm) return;
          const { kind, row } = confirm;
          setConfirm(null);
          void runAction(kind, row.id);
        }}
      />
    </>
  );
}
