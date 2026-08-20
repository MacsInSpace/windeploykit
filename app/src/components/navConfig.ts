// Sidebar nav — the MDT Deployment Workbench console tree.
//
// One vertical tree down the left, exactly like the Workbench: a Deployment
// Share root with its child nodes nested under it, then Monitoring and Advanced
// Configuration as siblings. No plug-in registry, no theme packages — every
// node below is always present, and `id` is the panel key the router dispatches.

export interface NavNode {
  id: string;
  label: string;
  icon: string;
  /** Nested child nodes, rendered indented under this one. */
  children?: NavNode[];
  /** Root nodes render as a tree parent — bold, always expanded. */
  root?: boolean;
  badge?: string | number;
  badgeVariant?: "ok" | "warn";
  /** Needs the deployment services (TFTP/HTTP/SMB) running on this machine. */
  servicesRequired?: boolean;
}

/**
 * The console tree. Depth 0 = the share root; depth 1 = its nodes.
 * Order mirrors MDT, with Netboot added after Boot Images.
 */
export const NAV_TREE: NavNode[] = [
  {
    id: "deployment-share",
    label: "Deployment Share",
    icon: "deployment-share",
    root: true,
    children: [
      // Deployment order, not MDT's alphabetical-ish one: Netboot owns the
      // services, Boot Images is what they serve, then the payload the booted
      // client applies, then what runs it, then what watches it.
      { id: "netboot", label: "Netboot", icon: "netboot" },
      { id: "boot-images", label: "Boot Images", icon: "boot-images" },
      { id: "operating-systems", label: "Operating Systems", icon: "operating-systems" },
      { id: "out-of-box-drivers", label: "Out-of-Box Drivers", icon: "out-of-box-drivers" },
      { id: "applications", label: "Applications", icon: "applications" },
      { id: "task-sequences", label: "Task Sequences", icon: "task-sequences" },
      { id: "monitoring", label: "Monitoring", icon: "monitoring", servicesRequired: true },
      {
        id: "advanced",
        label: "Advanced Configuration",
        icon: "advanced",
        children: [
          { id: "site-profile", label: "Site Profile", icon: "site-profile" },
          { id: "transfers", label: "Transfers", icon: "transfers" },
          { id: "logs", label: "Sidecar Log", icon: "logs" },
        ],
      },
    ],
  },
];

/** Flat list of every selectable node id, in tree order. */
export function flattenNav(nodes: NavNode[] = NAV_TREE): NavNode[] {
  const out: NavNode[] = [];
  for (const n of nodes) {
    out.push(n);
    if (n.children) out.push(...flattenNav(n.children));
  }
  return out;
}

export function findNavNode(id: string): NavNode | undefined {
  return flattenNav().find((n) => n.id === id);
}
