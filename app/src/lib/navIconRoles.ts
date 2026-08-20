// Nav id → icon role for the console tree. Plain map, no theme packages.
// Values must be keys of the PATHS table in components/AppIcon.tsx.

export const NAV_ICON_ROLES = {
  "deployment-share": "server",
  "operating-systems": "boot",
  "out-of-box-drivers": "switch",
  applications: "package",
  "task-sequences": "list",
  "boot-images": "laptop",
  netboot: "network",
  monitoring: "analytics",
  advanced: "settings",
  "site-profile": "building",
  transfers: "download",
  logs: "terminal",
} as const;

export type IconRole = (typeof NAV_ICON_ROLES)[keyof typeof NAV_ICON_ROLES];
