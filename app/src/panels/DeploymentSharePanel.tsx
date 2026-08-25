/**
 * Deployment Share root - the share's own properties, as in MDT where selecting
 * the share root shows what it is and where it lives.
 *
 * The one setting that matters here is the Deploy$ base: where ISOs, OS WIMs and
 * driver packs are stored and served from. Boot images, the TFTP root and configs
 * deliberately stay in app data (AGENT_NOTES.md section 3b).
 */
import { useCallback, useEffect, useMemo, useState } from "react";

import { PanelShell } from "../components/PanelShell";
import { useConsoleActions, type ConsoleNodeActions } from "../state/consoleActions";
import { SetupWizard } from "../components/SetupWizard";
import { updateDeploymentShare } from "../lib/deploymentShare";
import {
  formatBytes,
  getImageLibraryFreeSpace,
  getImageLibraryRoot,
  type FreeSpaceInfo,
} from "../lib/imageLibrary";
import { SETTING_IMAGE_LIBRARY_DIR } from "../lib/downloadSettings";
import { getSetting, subscribeSettings } from "../lib/settings";

const SUBFOLDERS: Array<[string, string]> = [
  ["iso/", "Windows ISOs, mounted read-only and served in place"],
  ["WIMs/", "Operating-system images"],
  ["Drivers/", "Vendor driver packs, by make and model"],
  [".incoming/", "Download staging"],
];

export function DeploymentSharePanel() {
  const [root, setRoot] = useState("");
  const [space, setSpace] = useState<FreeSpaceInfo | null>(null);
  const [editing, setEditing] = useState(false);
  const [updating, setUpdating] = useState(false);
  const [, setTick] = useState(0);

  useEffect(() => subscribeSettings(() => setTick((n) => n + 1)), []);

  const refresh = useCallback(() => {
    void getImageLibraryRoot().then(setRoot);
    void getImageLibraryFreeSpace().then(setSpace);
  }, []);

  useEffect(refresh, [refresh, editing]);

  // Properties... is the Workbench verb for the share root; it opens the same
  // wizard first run used. Registered with the shell, not drawn here.
  const openProperties = useCallback(() => setEditing(true), []);
  // Update Deployment Share - the Workbench's first verb on the share root. Ours
  // regenerates everything the services serve and touches no process (Netboot has
  // Restart Services for that), so it is safe while devices are imaging.
  const runUpdate = useCallback(async () => {
    setUpdating(true);
    try {
      await updateDeploymentShare();
    } finally {
      setUpdating(false);
      refresh();
    }
  }, [refresh]);
  const consoleActions = useMemo<ConsoleNodeActions>(
    () => ({
      // The shell renders Properties... itself (bold, Alt+Enter) from `properties`,
      // so it is not repeated in `items` - that showed the verb twice.
      items: [
        {
          label: updating ? "Updating..." : "Update Deployment Share",
          disabled: updating,
          onSelect: () => void runUpdate(),
        },
      ],
      properties: openProperties,
      refresh,
    }),
    [openProperties, refresh, runUpdate, updating],
  );
  useConsoleActions(consoleActions);

  const override = String(getSetting(SETTING_IMAGE_LIBRARY_DIR)).trim();
  const low = space?.ok && space.freeBytes != null && space.freeBytes < 20 * 1024 ** 3;

  return (
    <>
      <PanelShell
        title="Deployment Share"
        subtitle={root ? <span className="mono">{root}</span> : undefined}
        details={[
          { label: "Source", value: override ? "custom folder" : "default location" },
          space?.ok && space.freeBytes != null
            ? {
                label: "Free",
                value: `${formatBytes(space.freeBytes)}${
                  space.totalBytes != null ? ` of ${formatBytes(space.totalBytes)}` : ""
                }`,
                tone: low ? "warn" : "normal",
              }
            : false,
          { label: "Boot files", value: "app data (not here)" },
        ]}
      >
        <div className="flex flex-col gap-4 px-5 py-4">
          <section>
            <div
              className="mono mb-2 text-[9px] font-medium uppercase"
              style={{ color: "var(--text3)", letterSpacing: "0.15em" }}
            >
              Deploy$ base
            </div>
            <div
              className="rounded-sm px-3 py-2"
              style={{ background: "var(--surface2)", border: "1px solid var(--border)" }}
            >
              {SUBFOLDERS.map(([dir, what]) => (
                <div key={dir} className="flex items-baseline gap-2 py-0.5">
                  <span
                    className="mono text-[11px]"
                    style={{ color: "var(--text)", minWidth: 84 }}
                  >
                    {dir}
                  </span>
                  <span className="text-[11px]" style={{ color: "var(--text3)" }}>
                    {what}
                  </span>
                </div>
              ))}
            </div>
            {low ? (
              <div className="mt-2 text-[11.5px]" style={{ color: "var(--amber)" }}>
                ! Under 20 GB free - a single Windows ISO plus driver packs may not fit.
              </div>
            ) : null}
          </section>
        </div>
      </PanelShell>

      <SetupWizard open={editing} dismissable onDone={() => setEditing(false)} />
    </>
  );
}
