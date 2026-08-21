/** Boot Images - the boot WIM library served over TFTP/HTTP. */
import { PxeWorkspace } from "../workspaces/PxeWorkspace";

export function BootImagesPanel() {
  return <PxeWorkspace sections={["bootImages"]} title="Boot Images" />;
}
