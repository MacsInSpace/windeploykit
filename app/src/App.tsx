/**
 * App shell — MDT console tree on the left, one panel per node on the right.
 *
 * No sign-in gate and no boot overlay: WinDeployKit has no directory session, so
 * the workspace is live from first paint.
 */
import { useState } from "react";

import { Sidebar } from "./components/Sidebar";
import { findNavNode } from "./components/navConfig";
import { NetbootPanel } from "./panels/NetbootPanel";
import { MonitoringPanel } from "./panels/MonitoringPanel";
import { BootImagesPanel } from "./panels/BootImagesPanel";
import { TaskSequencesPanel } from "./panels/TaskSequencesPanel";
import { OperatingSystemsPanel } from "./panels/OperatingSystemsPanel";
import { OutOfBoxDriversPanel } from "./panels/OutOfBoxDriversPanel";
import { TransfersPanel } from "./panels/TransfersPanel";

export default function App() {
  const [activeId, setActiveId] = useState("netboot");
  const node = findNavNode(activeId);

  return (
    <div className="app-shell flex h-full min-h-0">
      <Sidebar activeId={activeId} onSelect={setActiveId} />
      <main className="app-main flex min-h-0 min-w-0 flex-1 flex-col">
        {renderPanel(activeId, node?.label ?? "")}
      </main>
    </div>
  );
}

function renderPanel(id: string, label: string) {
  switch (id) {
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

/** Placeholder for nodes with no panel yet (Deployment Share, Applications, Site Profile, Sidecar Log). */
function NotBuiltYet({ label, id }: { label: string; id: string }) {
  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="panel-header">
        <h1 className="panel-title">{label}</h1>
      </header>
      <div className="flex flex-1 items-center justify-center">
        <p className="empty-state mono">{id} — panel not built yet</p>
      </div>
    </div>
  );
}
