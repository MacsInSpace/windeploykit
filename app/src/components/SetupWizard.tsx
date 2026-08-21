/**
 * First-run setup - choose the Deploy$ base.
 *
 * MDT shows a New Deployment Share Wizard before the console is usable; this is
 * the same idea reduced to the one decision WinDeployKit cannot guess: where the
 * large imaging data lives.
 *
 * Why this exists at all: the sidecar honours a user-chosen image library root,
 * but until this wizard landed nothing in the UI could set one, so every install
 * silently used the default. See AGENT_NOTES.md section 3b for the storage split
 * this enforces - boot images and the TFTP root stay in app data, ISOs and driver
 * packs go here.
 */
import { useCallback, useEffect, useState } from "react";
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
import { getSetting, setSetting } from "../lib/settings";

interface SetupWizardProps {
  open: boolean;
  /** Wizard runs on first launch; Settings reuses it with a Cancel path. */
  dismissable?: boolean;
  onDone: () => void;
}

export function SetupWizard({ open: isOpen, dismissable = false, onDone }: SetupWizardProps) {
  const [resolved, setResolved] = useState("");
  const [space, setSpace] = useState<FreeSpaceInfo | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const override = String(getSetting(SETTING_IMAGE_LIBRARY_DIR)).trim();

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

  const finish = useCallback(async () => {
    setBusy(true);
    setError(null);
    try {
      const pushed = await pushImageLibraryRoot();
      if (!pushed) {
        setError("Could not resolve the Deploy$ base. Pick a folder and try again.");
        return;
      }
      setSetting(SETTING_SETUP_COMPLETED, true);
      onDone();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, [onDone]);

  return (
    <Modal
      open={isOpen}
      title="WinDeployKit setup"
      subtitle="Choose where imaging data is stored"
      onClose={dismissable ? onDone : () => undefined}
      lock={!dismissable || busy}
      allowBusyCancel={dismissable}
      onCancelWhileBusy={dismissable ? onDone : undefined}
      width={560}
      footer={
        <div className="flex items-center justify-between gap-2">
          <span className="mono text-[10px]" style={{ color: "var(--text3)" }}>
            Changeable later under Deployment Share
          </span>
          <div className="flex items-center gap-2">
            {dismissable ? (
              <button type="button" className="btn" onClick={onDone} disabled={busy}>
                Cancel
              </button>
            ) : null}
            <button
              type="button"
              className="btn btn-primary"
              onClick={() => void finish()}
              disabled={busy || !resolved}
            >
              {busy ? "Saving..." : "Finish"}
            </button>
          </div>
        </div>
      }
    >
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
    </Modal>
  );
}
