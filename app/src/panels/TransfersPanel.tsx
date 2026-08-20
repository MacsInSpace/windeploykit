/**
 * Transfers — the download client. Every in-flight transfer (torrent and HTTP),
 * a manual add box, and the acquisition settings.
 *
 * Catalogs deliberately live with their content instead: OS images under
 * Operating Systems, driver packs under Out-of-Box Drivers.
 */
import { ContentWorkspace } from "../workspaces/ContentWorkspace";

export function TransfersPanel() {
  return <ContentWorkspace tabs={["add", "settings"]} title="Transfers" icon="transfers" />;
}
