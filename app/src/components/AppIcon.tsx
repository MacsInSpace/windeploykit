import type { ReactNode } from "react";

import { NAV_ICON_ROLES } from "../lib/navIconRoles";

interface AppIconProps {
  name: string;
  size?: number;
  strokeWidth?: number;
  className?: string;
}

/** Every glyph this component can draw - the keys of PATHS below. */
type IconKind = keyof typeof PATHS;

function iconKind(name: string): IconKind {
  const token = name.toLowerCase();
  // A nav id maps straight to its role; anything else falls back to the generic
  // glyph. The upstream keyword heuristics went with the panels that used them.
  const routeRole = NAV_ICON_ROLES[token as keyof typeof NAV_ICON_ROLES];
  if (routeRole && routeRole in PATHS) return routeRole as IconKind;
  if (token in PATHS) return token as IconKind;
  return "tool";
}

const PATHS = {
  laptop: <><path d="M5 5h14v11H5zM3 19h18l-1 2H4l-1-2Z" /></>,
  network: <><circle cx="12" cy="5" r="2.5" /><circle cx="5" cy="18" r="2.5" /><circle cx="19" cy="18" r="2.5" /><path d="m10.5 7-4 8.5M13.5 7l4 8.5M7.5 18h9" /></>,
  server: <><rect x="3" y="4" width="18" height="6" rx="2" /><rect x="3" y="14" width="18" height="6" rx="2" /><path d="M7 7h.01M7 17h.01M11 7h6M11 17h6" /></>,
  list: <><path d="M9 6h11M9 12h11M9 18h11" /><path d="M4 6h.01M4 12h.01M4 18h.01" /></>,
  analytics: <><path d="M4 20V10M10 20V4M16 20v-7M22 20H2" /><path d="m3 7 6-4 6 5 6-4" /></>,
  switch: <><rect x="3" y="6" width="18" height="12" rx="2" /><path d="M7 10h.01M10 10h.01M13 10h.01M16 10h.01M7 14h4M17 14h-3M16 12l2 2-2 2M8 12l-2 2 2 2" /></>,
  building: <><path d="M4 21V6l8-3 8 3v15M8 9h.01M12 9h.01M16 9h.01M8 13h.01M12 13h.01M16 13h.01M10 21v-4h4v4" /></>,
  settings: <><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.05.05-2.83 2.83-.05-.05A1.7 1.7 0 0 0 15 19.4a1.7 1.7 0 0 0-1 1.55V21h-4v-.05a1.7 1.7 0 0 0-1-1.55 1.7 1.7 0 0 0-1.9.34l-.04.05-2.83-2.83.05-.05A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-1.55-1H3v-4h.05A1.7 1.7 0 0 0 4.6 9a1.7 1.7 0 0 0-.34-1.9l-.05-.04 2.83-2.83.05.05A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-1.55V3h4v.05A1.7 1.7 0 0 0 15 4.6a1.7 1.7 0 0 0 1.9-.34l.04-.05 2.83 2.83-.05.05A1.7 1.7 0 0 0 19.4 9a1.7 1.7 0 0 0 1.55 1H21v4h-.05A1.7 1.7 0 0 0 19.4 15Z" /></>,
  boot: <><rect x="3" y="4" width="18" height="13" rx="2" /><path d="M12 14V7M9 10l3-3 3 3M8 21h8M12 17v4" /></>,
  download: <><path d="M12 3v12M7 10l5 5 5-5" /><path d="M4 19v2h16v-2" /></>,
  package: <><path d="m4 7 8-4 8 4-8 4-8-4Z" /><path d="m4 7v10l8 4 8-4V7M12 11v10" /></>,
  terminal: <><rect x="3" y="4" width="18" height="16" rx="2" /><path d="m7 9 3 3-3 3M13 15h4" /></>,
  tool: <><path d="M14.7 6.3a4 4 0 0 0-5-5L7.4 3.6l3 3 2.3-2.3a4 4 0 0 0 2 5L7 17l-3 3 1 1 3-3 7.7-7.7a4 4 0 0 0-1-4Z" /></>,
} satisfies Record<string, ReactNode>;

export function AppIcon({ name, size = 18, strokeWidth = 1.8, className = "" }: AppIconProps) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {PATHS[iconKind(name)]}
    </svg>
  );
}
