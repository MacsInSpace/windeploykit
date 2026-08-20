/**
 * Operating Systems — the OS image library and its acquisition sources
 * (Evaluation Center ISOs, torrent catalog, OEM ISOs, manual URL).
 */
import { ContentWorkspace } from "../workspaces/ContentWorkspace";

export function OperatingSystemsPanel() {
  return <ContentWorkspace tabs={["images"]} title="Operating Systems" icon="operating-systems" />;
}
