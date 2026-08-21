/**
 * App - the MMC console shell with one panel per tree node.
 *
 * No sign-in gate and no boot overlay: WinDeployKit has no directory session,
 * so the console is live from first paint. The one thing that gates the first
 * launch is setup: the Deploy$ base has to be chosen before anything can be
 * downloaded or served (components/SetupWizard.tsx).
 */
import { useEffect, useState } from "react";

import { ConsoleShell } from "./components/ConsoleShell";
import { SetupWizard } from "./components/SetupWizard";
import { findNavNode } from "./components/navConfig";
import { NetbootPanel } from "./panels/NetbootPanel";
import { MonitoringPanel } from "./panels/MonitoringPanel";
import { BootImagesPanel } from "./panels/BootImagesPanel";
import { TaskSequencesPanel } from "./panels/TaskSequencesPanel";
import { OperatingSystemsPanel } from "./panels/OperatingSystemsPanel";
import { OutOfBoxDriversPanel } from "./panels/OutOfBoxDriversPanel";
import { TransfersPanel } from "./panels/TransfersPanel";
import { DeploymentSharePanel } from "./panels/DeploymentSharePanel";
import { SidecarLogPanel } from "./panels/SidecarLogPanel";
import { SETTING_SETUP_COMPLETED } from "./lib/setupSettings";
import { getSetting } from "./lib/settings";
import { pushImageLibraryRoot } from "./lib/imageLibrary";
import { ensureSidecarStarted } from "./lib/sidecarBoot";

export default function App() {
  const [setupOpen, setSetupOpen] = useState(() => !getSetting(SETTING_SETUP_COMPLETED));

  // Start the sidecar. The Rust host waits for this call; nothing else makes it.
  useEffect(() => {
    void ensureSidecarStarted();
  }, []);

  // The sidecar keys promote, import, Caddy routes and the SMB share off the
  // image library root, and only learns it when the frontend pushes it.
  // sidecarBoot repeats this once the sidecar is actually ready.
  useEffect(() => {
    if (setupOpen) return;
    void pushImageLibraryRoot();
  }, [setupOpen]);

  return (
    <>
      <ConsoleShell initialId="deployment-share" renderPanel={renderPanel} />
      <SetupWizard open={setupOpen} onDone={() => setSetupOpen(false)} />
    </>
  );
}

function renderPanel(id: string) {
  switch (id) {
    case "deployment-share":
      return <DeploymentSharePanel />;
    case "operating-systems":
      return <OperatingSystemsPanel />;
    case "out-of-box-drivers":
      return <OutOfBoxDriversPanel />;
    case "task-sequences":
      return <TaskSequencesPanel />;
    case "boot-images":
      return <BootImagesPanel />;
    case "netboot":
      return <NetbootPanel />;
    case "monitoring":
      return <MonitoringPanel />;
    case "transfers":
      return <TransfersPanel />;
    case "logs":
      return <SidecarLogPanel />;
    default:
      return <NotBuiltYet id={id} />;
  }
}

/** Placeholder for nodes with no panel yet (Applications, Site Profile). */
function NotBuiltYet({ id }: { id: string }) {
  const label = findNavNode(id)?.label ?? id;
  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="results-head">
        <span className="results-title">{label}</span>
      </div>
      <div className="flex flex-1 items-center justify-center">
        <p className="empty-state mono">{id} - panel not built yet</p>
      </div>
    </div>
  );
}
