/** Task Sequences — named deployment recipes that compile to unattend.xml. */
import { PxeWorkspace } from "../workspaces/PxeWorkspace";

export function TaskSequencesPanel() {
  return <PxeWorkspace sections={["taskSequences"]} title="Task Sequences" icon="task-sequences" />;
}
