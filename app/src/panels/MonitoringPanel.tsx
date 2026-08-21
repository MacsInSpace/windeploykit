/**
 * Monitoring - both deployment logs in one place.
 *   * PXE activity log   (dnsmasq/TFTP: which client fetched which boot file)
 *   * Imaging clients    (per-device log streamed back during deployment)
 * Both are clearable.
 */
import { PxeWorkspace } from "../workspaces/PxeWorkspace";

export function MonitoringPanel() {
  return <PxeWorkspace sections={["pxeLog", "imagingClients"]} title="Monitoring" icon="monitoring" />;
}
