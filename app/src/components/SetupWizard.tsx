/**
 * First-run setup - two decisions MDT makes you take before the console is usable,
 * and nothing more:
 *
 *   1. Deploy$ base - where the large imaging data lives (ISOs, WIMs, driver packs).
 *   2. Tools - what the app needs and does not carry inside the bundle, obtained from
 *      each tool's own upstream project (Caddy from GitHub, Tftpd64 from GitHub, aria2
 *      from GitHub on Windows, 7-Zip from 7-zip.org on macOS). Bundled tools (dnsmasq,
 *      wimlib-imagex, aria2c on macOS) are shown for completeness. Homebrew is never
 *      consulted (Craig, 2026-08-29: treat it as not installed). Same shape as
 *      AdobeUpdateKit's "Download tools" step.
 *
 * Why step 1 exists at all: the sidecar honours a user-chosen image library root, but
 * until this wizard landed nothing in the UI could set one, so every install silently
 * used the default. See AGENT_NOTES.md section 3b for the storage split this enforces.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";

import { Modal } from "./Modal";
import { SETTING_IMAGE_LIBRARY_DIR } from "../lib/downloadSettings";
import { SETTING_SETUP_COMPLETED } from "../lib/setupSettings";
import {
  formatBytes,
  getImageLibraryFreeSpace,
  getImageLibraryRoot,
  pushImageLibraryRoot,
  type FreeSpaceInfo,
} from "../lib/imageLibrary";
import { sidecar } from "../lib/ipc";
import { getSetting, setSetting } from "../lib/settings";
import type { EnsureToolsResult, ToolsStatus } from "../lib/types";

interface SetupWizardProps {
  open: boolean;
  /** Wizard runs on first launch; Settings reuses it with a Cancel path. */
  dismissable?: boolean;
  onDone: () => void;
}

type StepId = "base" | "tools";
const STEPS: StepId[] = ["base", "tools"];
const STEP_LABEL: Record<StepId, string> = { base: "Deploy$ base", tools: "Tools" };

export function SetupWizard({ open: isOpen, dismissable = false, onDone }: SetupWizardProps) {
  const [step, setStep] = useState<StepId>("base");
  const [resolved, setResolved] = useState("");
  const [space, setSpace] = useState<FreeSpaceInfo | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [tools, setTools] = useState<ToolsStatus | null>(null);
  const [toolsLoading, setToolsLoading] = useState(false);
  const [toolsBusy, setToolsBusy] = useState(false);
  const [toolLines, setToolLines] = useState<string[]>([]);

  const override = String(getSetting(SETTING_IMAGE_LIBRARY_DIR)).trim();
  const stepIndex = STEPS.indexOf(step);

  useEffect(() => {
    if (!isOpen) return;
    setStep("base");
    setError(null);
    setToolLines([]);
  }, [isOpen]);

  useEffect(() => {
    if (!isOpen) return;
    let live = true;
    void getImageLibraryRoot().then((r) => {
      if (live) setResolved(r);
    });
    // Free space is the whole reason this folder is a decision: a Windows ISO plus
    // one driver pack set can run to tens of GB.
    void getImageLibraryFreeSpace().then((s) => {
      if (live) setSpace(s);
    });
    return () => {
      live = false;
    };
  }, [isOpen, override]);

  const loadTools = useCallback(async () => {
    setToolsLoading(true);
    try {
      const t = await sidecar.invoke<ToolsStatus>("GetTools", {});
      setTools(t);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setToolsLoading(false);
    }
  }, []);

  // Entering the tools step takes a fresh inventory - a tool obtained by another
  // panel since the last look must show as present.
  useEffect(() => {
    if (isOpen && step === "tools") void loadTools();
  }, [isOpen, step, loadTools]);

  const browse = useCallback(async () => {
    setError(null);
    const picked = await open({
      directory: true,
      multiple: false,
      title: "Choose the Deploy$ base",
      defaultPath: override || resolved || undefined,
    });
    if (!picked || typeof picked !== "string") return;
    setSetting(SETTING_IMAGE_LIBRARY_DIR, picked);
    setResolved(picked);
  }, [override, resolved]);

  const useDefault = useCallback(() => {
    setError(null);
    setSetting(SETTING_IMAGE_LIBRARY_DIR, SETTING_IMAGE_LIBRARY_DIR.defaultValue);
  }, []);

  // Step 1 -> 2: the base is pushed to the sidecar first, so the tool installs that
  // follow land in a store whose layout already knows the Deploy$ root.
  const saveBase = useCallback(async () => {
    setBusy(true);
    setError(null);
    try {
      const pushed = await pushImageLibraryRoot();
      if (!pushed) {
        setError("Could not resolve the Deploy$ base. Pick a folder and try again.");
        return false;
      }
      return true;
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      return false;
    } finally {
      setBusy(false);
    }
  }, []);

  const next = useCallback(async () => {
    if (step === "base") {
      if (await saveBase()) setStep("tools");
    }
  }, [step, saveBase]);

  // One action for every downloadable tool: EnsureTools obtains each from its
  // upstream project and reports per-tool lines. A failure never blocks Finish - the
  // Netboot / Downloads panels retry on demand and say what is missing.
  const downloadTools = useCallback(async () => {
    setToolsBusy(true);
    setError(null);
    setToolLines([]);
    try {
      const r = await sidecar.invoke<EnsureToolsResult>("EnsureTools", {});
      setToolLines(r.lines ?? []);
      setTools(r.tools);
      if (!r.ok && r.failures?.length) {
        setError(
          `${r.failures.length} tool(s) could not be obtained: ${r.failures
            .map((f) => `${f.tool} - ${f.message}`)
            .join("; ")}`,
        );
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setToolsBusy(false);
    }
  }, []);

  const finish = useCallback(() => {
    setSetting(SETTING_SETUP_COMPLETED, true);
    onDone();
  }, [onDone]);

  const downloadable = useMemo(
    () => (tools ? tools.rows.filter((r) => r.downloadable && !r.present) : []),
    [tools],
  );
  const anyBusy = busy || toolsBusy;

  return (
    <Modal
      open={isOpen}
      title="WinDeployKit setup"
      subtitle={step === "base" ? "Choose where imaging data is stored" : "Obtain the tools the app needs"}
      onClose={dismissable ? onDone : () => undefined}
      lock={!dismissable || anyBusy}
      allowBusyCancel={dismissable}
      onCancelWhileBusy={dismissable ? onDone : undefined}
      width={600}
      footer={
        <div className="flex items-center justify-between gap-2">
          <span className="mono text-[10px]" style={{ color: "var(--text3)" }}>
            Step {stepIndex + 1} of {STEPS.length} - {STEP_LABEL[step]}
            {step === "base" ? " - changeable later under Deployment Share" : ""}
          </span>
          <div className="flex items-center gap-2">
            {dismissable ? (
              <button type="button" className="btn" onClick={onDone} disabled={anyBusy}>
                Cancel
              </button>
            ) : null}
            {step === "tools" ? (
              <button type="button" className="btn" onClick={() => setStep("base")} disabled={anyBusy}>
                Back
              </button>
            ) : null}
            {step === "base" ? (
              <button
                type="button"
                className="btn btn-primary"
                onClick={() => void next()}
                disabled={anyBusy || !resolved}
              >
                {busy ? "Saving..." : "Next"}
              </button>
            ) : (
              <button
                type="button"
                className="btn btn-primary"
                onClick={finish}
                disabled={anyBusy}
                title={
                  tools && tools.missingRequired > 0
                    ? `${tools.missingRequired} required tool(s) still missing - the Netboot and Downloads panels will offer them again`
                    : undefined
                }
              >
                Finish
              </button>
            )}
          </div>
        </div>
      }
    >
      {step === "base" ? (
        <div className="flex flex-col gap-3">
          <div className="text-[12px]" style={{ color: "var(--text2)" }}>
            The <span className="mono">Deploy$</span> base holds ISOs, operating-system
            WIMs and driver packs. These run to tens of gigabytes, so they are kept off
            the system drive and served from here over HTTP and SMB.
          </div>

          <div>
            <div className="flex items-center gap-2">
              <div className="flex-1 text-[12px]" style={{ color: "var(--text)" }}>
                Deploy$ base
              </div>
              <span
                className="badge badge-dim mono"
                title={
                  override
                    ? "An explicit folder you chose"
                    : "Default location - macOS uses ~/Public because Downloads, Desktop and Documents are TCC-protected and cannot be served over SMB"
                }
              >
                {override ? "custom" : "default"}
              </span>
            </div>
            <div className="mt-2 flex flex-wrap items-center gap-2">
              <div
                className="input-box mono min-w-0 flex-1 text-[11px]"
                style={{ color: resolved ? "var(--text)" : "var(--text3)" }}
                title={resolved}
              >
                {resolved || "(resolving...)"}
              </div>
              <button type="button" className="btn" onClick={() => void browse()} disabled={busy}>
                Browse...
              </button>
              <button
                type="button"
                className="btn"
                onClick={useDefault}
                disabled={busy || !override}
                title="Use the default location"
              >
                Reset
              </button>
            </div>
            {space?.ok && space.freeBytes != null ? (
              <div className="mono mt-1.5 text-[10px]" style={{ color: "var(--text3)" }}>
                {formatBytes(space.freeBytes)} free
                {space.totalBytes != null ? ` of ${formatBytes(space.totalBytes)}` : ""}
              </div>
            ) : null}
          </div>

          {resolved ? (
            <div>
              <div
                className="mono mb-1 text-[9px] font-medium uppercase"
                style={{ color: "var(--text3)", letterSpacing: "0.15em" }}
              >
                Created here
              </div>
              <div
                className="rounded-sm px-3 py-2"
                style={{ background: "var(--surface2)", border: "1px solid var(--border)" }}
              >
                {[
                  ["iso/", "Windows ISOs, mounted read-only and served in place"],
                  ["WIMs/", "Operating-system images"],
                  ["Drivers/", "Vendor driver packs, by make and model"],
                  [".incoming/", "Download staging"],
                ].map(([dir, what]) => (
                  <div key={dir} className="flex items-baseline gap-2 py-0.5">
                    <span className="mono text-[11px]" style={{ color: "var(--text)", minWidth: 84 }}>
                      {dir}
                    </span>
                    <span className="text-[11px]" style={{ color: "var(--text3)" }}>
                      {what}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          ) : null}

          {error ? (
            <div className="text-[11.5px]" style={{ color: "var(--red)" }}>
              {error}
            </div>
          ) : null}
        </div>
      ) : (
        <div className="flex flex-col gap-3">
          <div className="text-[12px]" style={{ color: "var(--text2)" }}>
            Each tool comes from its own project - Caddy and Tftpd64 from GitHub, aria2 from
            GitHub, 7-Zip from 7-zip.org. Tools marked <span className="mono">bundled</span> are
            built into the app. Nothing is looked for in Homebrew or any package manager.
          </div>

          <div
            className="rounded-sm px-3 py-2"
            style={{ background: "var(--surface2)", border: "1px solid var(--border)" }}
          >
            {toolsLoading && !tools ? (
              <div className="mono text-[11px]" style={{ color: "var(--text3)" }}>
                Checking tools...
              </div>
            ) : tools ? (
              tools.rows.map((row) => (
                <div key={row.id} className="flex items-baseline gap-2 py-0.5" title={row.path ?? row.note ?? undefined}>
                  <span
                    className="mono text-[11px]"
                    style={{ color: "var(--text)", minWidth: 190 }}
                  >
                    {row.label}
                    {row.version ? <span style={{ color: "var(--text3)" }}> {row.version}</span> : null}
                  </span>
                  <span
                    className="badge mono"
                    style={{
                      color: row.present ? "var(--green)" : row.optional ? "var(--text3)" : "var(--red)",
                    }}
                  >
                    {row.present ? "present" : row.optional ? "optional" : "missing"}
                  </span>
                  {row.bundled ? <span className="badge badge-dim mono">bundled</span> : null}
                  <span className="min-w-0 flex-1 truncate text-[11px]" style={{ color: "var(--text3)" }}>
                    {row.source}
                  </span>
                </div>
              ))
            ) : (
              <div className="mono text-[11px]" style={{ color: "var(--text3)" }}>
                Tool inventory unavailable.
              </div>
            )}
          </div>

          <div className="flex items-center gap-2">
            <button
              type="button"
              className="btn btn-primary"
              onClick={() => void downloadTools()}
              disabled={anyBusy || toolsLoading || !tools || downloadable.length === 0}
              title={
                downloadable.length === 0
                  ? "Every downloadable tool is present"
                  : `Obtain: ${downloadable.map((r) => r.label).join(", ")}`
              }
            >
              {toolsBusy
                ? "Downloading..."
                : downloadable.length === 0
                  ? "All tools present"
                  : `Download ${downloadable.length} tool${downloadable.length === 1 ? "" : "s"}`}
            </button>
            <button type="button" className="btn" onClick={() => void loadTools()} disabled={anyBusy || toolsLoading}>
              Re-check
            </button>
          </div>

          {toolLines.length > 0 ? (
            <div
              className="mono max-h-40 overflow-auto rounded-sm px-3 py-2 text-[10.5px]"
              style={{ background: "var(--surface2)", border: "1px solid var(--border)", color: "var(--text2)" }}
            >
              {toolLines.map((line, i) => (
                <div key={i}>{line}</div>
              ))}
            </div>
          ) : null}

          {error ? (
            <div className="text-[11.5px]" style={{ color: "var(--red)" }}>
              {error}
            </div>
          ) : null}
        </div>
      )}
    </Modal>
  );
}
