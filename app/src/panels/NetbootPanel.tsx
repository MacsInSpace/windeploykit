/** Netboot - the PXE services running on this host (ProxyDHCP/TFTP, HTTP, SMB). */
import { PxeWorkspace } from "../workspaces/PxeWorkspace";

export function NetbootPanel() {
  return <PxeWorkspace sections={["host"]} title="Netboot" icon="netboot" />;
}
