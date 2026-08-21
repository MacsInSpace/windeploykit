/**
 * Out-of-Box Drivers - the Drivers/<Make>/<Model> store plus vendor catalog
 * downloads (Dell, HP, Lenovo, Acer, Microsoft Surface).
 */
import { ContentWorkspace } from "../workspaces/ContentWorkspace";

export function OutOfBoxDriversPanel() {
  return <ContentWorkspace tabs={["drivers"]} title="Out-of-Box Drivers" />;
}
