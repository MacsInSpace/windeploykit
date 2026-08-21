import type { ReactNode } from "react";

import { NAV_ICON_ROLES } from "../lib/navIconRoles";

interface AppIconProps {
  name: string;
  size?: number;
  strokeWidth?: number;
  className?: string;
}

/** Every glyph this component can draw — the keys of PATHS below. */
type IconKind = keyof typeof PATHS;

function iconKind(name: string): IconKind {
  const token = name.toLowerCase();
  // A nav id maps straight to its role; anything else falls through to the
  // keyword heuristics so ad-hoc icon names still resolve to something sane.
  const routeRole = NAV_ICON_ROLES[token as keyof typeof NAV_ICON_ROLES];
  if (routeRole && routeRole in PATHS) return routeRole as IconKind;
  if (token in PATHS) return token as IconKind;
  if (token.includes("focus") || token.includes("work")) return "focus";
  if (token.includes("setting") || token.includes("setup")) return "settings";
  if (token.includes("computer") || token.includes("desktop")) return "computer";
  if (token.includes("server") || token.includes("account")) return "server";
  if (token.includes("wireless") || token.includes("wifi")) return "wireless";
  if (token.includes("search")) return "search";
  if (token.includes("mail") || token.includes("notify")) return "mail";
  if (token.includes("site")) return "site";
  if (token.includes("cloud")) return "cloud";
  if (token.includes("bookmark")) return "bookmark";
  if (token.includes("document") || token.includes("log")) return "policy";
  if (token.includes("user") || token.includes("staff") || token.includes("student")) return "person";
  return "tool";
}

const PATHS = {
  dashboard: <><rect x="3" y="3" width="7" height="7" rx="1.5" /><rect x="14" y="3" width="7" height="7" rx="1.5" /><rect x="3" y="14" width="7" height="7" rx="1.5" /><rect x="14" y="14" width="7" height="7" rx="1.5" /></>,
  key: <><circle cx="8" cy="12" r="4" /><path d="M12 12h9M17 12v3M20 12v2" /></>,
  computer: <><rect x="3" y="4" width="18" height="13" rx="2" /><path d="M8 21h8M12 17v4" /></>,
  laptop: <><path d="M5 5h14v11H5zM3 19h18l-1 2H4l-1-2Z" /></>,
  network: <><circle cx="12" cy="5" r="2.5" /><circle cx="5" cy="18" r="2.5" /><circle cx="19" cy="18" r="2.5" /><path d="m10.5 7-4 8.5M13.5 7l4 8.5M7.5 18h9" /></>,
  server: <><rect x="3" y="4" width="18" height="6" rx="2" /><rect x="3" y="14" width="18" height="6" rx="2" /><path d="M7 7h.01M7 17h.01M11 7h6M11 17h6" /></>,
  groups: <><circle cx="9" cy="8" r="3" /><circle cx="17" cy="9" r="2.5" /><path d="M3 20v-1a5 5 0 0 1 10 0v1M14 15.5a4.5 4.5 0 0 1 7 3.5v1" /></>,
  person: <><circle cx="12" cy="7" r="4" /><path d="M4 21a8 8 0 0 1 16 0" /></>,
  student: <><path d="m3 9 9-5 9 5-9 5-9-5Z" /><path d="M7 12v4c2.8 2 7.2 2 10 0v-4M21 9v6" /></>,
  technician: <><path d="M14.5 6.5a4 4 0 0 0-5-5L8 3l3 3 1.5-1.5a4 4 0 0 0 3 5L8 17l-3 3 1 1 3-3 7.5-7.5a4 4 0 0 0-2-4Z" /><path d="m16 15 5 5" /></>,
  list: <><path d="M9 6h11M9 12h11M9 18h11" /><path d="M4 6h.01M4 12h.01M4 18h.01" /></>,
  certificate: <><path d="M5 3h11l3 3v11H5V3Z" /><path d="M15 3v4h4M8 10h7M8 13h4" /><circle cx="15.5" cy="17" r="2.5" /><path d="m14 19-1 3 2.5-1 2.5 1-1-3" /></>,
  analytics: <><path d="M4 20V10M10 20V4M16 20v-7M22 20H2" /><path d="m3 7 6-4 6 5 6-4" /></>,
  radio: <><path d="M4 15a8 8 0 0 1 16 0M7 15a5 5 0 0 1 10 0" /><circle cx="12" cy="15" r="1.5" /><path d="M12 17v4" /></>,
  compass: <><circle cx="12" cy="12" r="9" /><path d="m15.5 8.5-2 5-5 2 2-5 5-2Z" /></>,
  globe: <><circle cx="12" cy="12" r="9" /><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18" /></>,
  calendar: <><rect x="3" y="5" width="18" height="16" rx="2" /><path d="M8 3v4M16 3v4M3 10h18M8 14h.01M12 14h.01M16 14h.01M8 18h.01M12 18h.01" /></>,
  sun: <><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.93 4.93l1.42 1.42M17.65 17.65l1.42 1.42M2 12h2M20 12h2M4.93 19.07l1.42-1.42M17.65 6.35l1.42-1.42" /></>,
  shield: <><path d="M12 3 20 6v5c0 5-3.4 8.4-8 10-4.6-1.6-8-5-8-10V6l8-3Z" /><path d="m9 12 2 2 4-5" /></>,
  wireless: <><path d="M5 12.5a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0M12 20h.01" /></>,
  mobile: <><rect x="7" y="2" width="10" height="20" rx="2" /><path d="M11 18h2" /></>,
  switch: <><rect x="3" y="6" width="18" height="12" rx="2" /><path d="M7 10h.01M10 10h.01M13 10h.01M16 10h.01M7 14h4M17 14h-3M16 12l2 2-2 2M8 12l-2 2 2 2" /></>,
  branch: <><circle cx="6" cy="5" r="2" /><circle cx="18" cy="5" r="2" /><circle cx="12" cy="19" r="2" /><path d="M6 7v3c0 2 1 3 3 3h3M18 7v3c0 2-1 3-3 3h-3v4" /></>,
  site: <><path d="m3 10 9-6 9 6-9 6-9-6Z" /><path d="M7 13.5V19h10v-5.5M21 10v6" /></>,
  book: <><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H11v16H6.5A2.5 2.5 0 0 0 4 21.5v-16ZM20 5.5A2.5 2.5 0 0 0 17.5 3H13v16h4.5a2.5 2.5 0 0 1 2.5 2.5v-16Z" /></>,
  building: <><path d="M4 21V6l8-3 8 3v15M8 9h.01M12 9h.01M16 9h.01M8 13h.01M12 13h.01M16 13h.01M10 21v-4h4v4" /></>,
  cloud: <path d="M17.5 19H6.7A4.7 4.7 0 0 1 6 9.65 6 6 0 0 1 17.4 8a4.5 4.5 0 0 1 .1 9Z" />,
  ticket: <><path d="M4 6h16v4a2 2 0 0 0 0 4v4H4v-4a2 2 0 0 0 0-4V6Z" /><path d="M9 9h6M9 13h4" /></>,
  clock: <><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></>,
  policy: <><path d="M6 3h9l3 3v15H6V3Z" /><path d="M14 3v4h4M9 11h6M9 15h3" /><path d="m14 17 1.5 1.5L19 15" /></>,
  settings: <><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.05.05-2.83 2.83-.05-.05A1.7 1.7 0 0 0 15 19.4a1.7 1.7 0 0 0-1 1.55V21h-4v-.05a1.7 1.7 0 0 0-1-1.55 1.7 1.7 0 0 0-1.9.34l-.04.05-2.83-2.83.05-.05A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-1.55-1H3v-4h.05A1.7 1.7 0 0 0 4.6 9a1.7 1.7 0 0 0-.34-1.9l-.05-.04 2.83-2.83.05.05A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-1.55V3h4v.05A1.7 1.7 0 0 0 15 4.6a1.7 1.7 0 0 0 1.9-.34l.04-.05 2.83 2.83-.05.05A1.7 1.7 0 0 0 19.4 9a1.7 1.7 0 0 0 1.55 1H21v4h-.05A1.7 1.7 0 0 0 19.4 15Z" /></>,
  printer: <><path d="M7 8V3h10v5M7 17H5a2 2 0 0 1-2-2v-4a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2h-2" /><path d="M7 14h10v7H7zM17 12h.01" /></>,
  search: <><circle cx="11" cy="11" r="7" /><path d="m20 20-4-4" /></>,
  unlock: <><rect x="5" y="10" width="14" height="11" rx="2" /><path d="M9 10V7a4 4 0 0 1 7-2" /></>,
  scan: <><circle cx="12" cy="12" r="3" /><circle cx="12" cy="12" r="8" /><path d="M12 2v3M12 19v3M2 12h3M19 12h3" /></>,
  boot: <><rect x="3" y="4" width="18" height="13" rx="2" /><path d="M12 14V7M9 10l3-3 3 3M8 21h8M12 17v4" /></>,
  download: <><path d="M12 3v12M7 10l5 5 5-5" /><path d="M4 19v2h16v-2" /></>,
  "cloud-computer": <><path d="M15.5 11H7.2A3.7 3.7 0 0 1 7 3.6 4.8 4.8 0 0 1 16.1 3a3.6 3.6 0 0 1-.6 8Z" /><rect x="5" y="14" width="14" height="7" rx="1.5" /><path d="M10 23h4" /></>,
  variables: <><path d="M8 4H5v16h3M16 4h3v16h-3" /><path d="m10 9 4 6M14 9l-4 6" /></>,
  package: <><path d="m4 7 8-4 8 4-8 4-8-4Z" /><path d="m4 7v10l8 4 8-4V7M12 11v10" /></>,
  mail: <><rect x="3" y="5" width="18" height="14" rx="2" /><path d="m3 7 9 6 9-6" /></>,
  terminal: <><rect x="3" y="4" width="18" height="16" rx="2" /><path d="m7 9 3 3-3 3M13 15h4" /></>,
  bookmark: <path d="M6 4.5A1.5 1.5 0 0 1 7.5 3h9A1.5 1.5 0 0 1 18 4.5V21l-6-4-6 4V4.5Z" />,
  focus: <><path d="M8 3H3v5M16 3h5v5M8 21H3v-5M16 21h5v-5" /><circle cx="12" cy="12" r="3" /></>,
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
