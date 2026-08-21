/**
 * App shell - MDT console tree on the left, one panel per node on the right.
 *
 * No sign-in gate and no boot overlay: WinDeployKit has no directory session, so
 * the workspace is live from first paint. The one thing that does gate the first
 * launch is setup: the Deploy$ base has to be chosen before anything can be
 * downloaded or served (see components/SetupWizard.tsx).
 */
import { useEffect, useState } from "react";

import { Sidebar } from "./components/Sidebar";
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
import { SETTING_SETUP_COMPLETED } from "./lib/setupSettings";
import { getSetting } from "./lib/settings";
import { pushImageLibraryRoot } from "./lib/imageLibrary";

export default function App() {
  const [activeId, setActiveId] = useState("netboot");
  const [setupOpen, setSetupOpen] = useState(() => !getSetting(SETTING_SETUP_COMPLETED));
  const node = findNavNode(activeId);

  // The sidecar keys promote, import, Caddy routes and the SMB share off the
  // image library root, and only learns it when the frontend pushes it. Nothing
  // called this before, so the sidecar always fell back to the default root no
  // matter what the setting said.
  useEffect(() => {
    if (setupOpen) return;
    void pushImageLibraryRoot();
  }, [setupOpen]);

  return (
    <div className="app-shell flex h-full min-h-0">
      <Sidebar activeId={activeId} onSelect={setActiveId} />
      <main className="app-main flex min-h-0 min-w-0 flex-1 flex-col">
        {renderPanel(activeId, node?.label ?? "")}
      </main>
      <SetupWizard open={setupOpen} onDone={() => setSetupOpen(false)} />
    </div>
  );
}

function renderPanel(id: string, label: string) {
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
    default:
      return <NotBuiltYet label={label} id={id} />;
  }
}

/** Placeholder for nodes with no panel yet (Applications, Site Profile, Sidecar Log). */
function NotBuiltYet({ label, id }: { label: string; id: string }) {
  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="panel-header">
        <h1 className="panel-title">{label}</h1>
      </header>
      <div className="flex flex-1 items-center justify-center">
        <p className="empty-state mono">{id} - panel not built yet</p>
      </div>
    </div>
  );
}
