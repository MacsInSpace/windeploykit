/**
 * Cache TTLs, registered as user-tweakable settings.
 *
 * Each slot is defined as a `defineSetting` call so the Settings
 * overlay picks them up automatically and persists user overrides
 * to localStorage. Build-time `.env.local` defaults (the
 * `VITE_TTL_*_MIN` vars) are honoured as a fallback layer below
 * runtime overrides. See `app/src/lib/settings.ts` for the read
 * order and `.env.local.example` for the env knobs.
 *
 * Stale-while-revalidate is on for every query, so longer TTLs
 * still feel fresh: the cached data renders instantly and a fresh
 * fetch lands in the background when the TTL expires.
 *
 * The exported `TTL` is a Proxy -- accessors always read the
 * latest value from the settings registry, so an overlay change
 * applies to the next fetch without needing a panel remount.
 * (In-flight cached entries keep their original expiry because
 * expiry is computed at fetch time, which is what we want.)
 */

import { defineSetting, getSetting } from "./settings";

const MS_PER_MIN = 60_000;
const GROUP = "Cache TTLs (minutes)";

const SETTINGS = {
  staff: defineSetting({
    id: "ttl.staffMin",
    group: GROUP,
    label: "Staff list",
    description:
      "Members of {SN}-gs-All Staff. Curated centrally; rarely changes mid-day.",
    type: "number",
    defaultValue: 30,
    unit: "min",
    min: 1,
    max: 24 * 60,
    envVar: "VITE_TTL_STAFF_MIN",
  }),
  students: defineSetting({
    id: "ttl.studentsMin",
    group: GROUP,
    label: "Students list",
    description:
      "Members of {SN}-gs-All Students. Refreshed when class lists change (start of term, etc.).",
    type: "number",
    defaultValue: 30,
    unit: "min",
    min: 1,
    max: 24 * 60,
    envVar: "VITE_TTL_STUDENTS_MIN",
  }),
  serviceAccounts: defineSetting({
    id: "ttl.serviceAccountsMin",
    group: GROUP,
    label: "Service accounts",
    description:
      "OU=Service Accounts members. Changes only when techs create / disable / reset them.",
    type: "number",
    defaultValue: 30,
    unit: "min",
    min: 1,
    max: 24 * 60,
    envVar: "VITE_TTL_SERVICE_ACCOUNTS_MIN",
  }),
  groups: defineSetting({
    id: "ttl.groupsMin",
    group: GROUP,
    label: "Group list",
    description: "{SN}-gs-* group catalog at this school. New groups appear rarely.",
    type: "number",
    defaultValue: 30,
    unit: "min",
    min: 1,
    max: 24 * 60,
    envVar: "VITE_TTL_GROUPS_MIN",
  }),
  groupMembers: defineSetting({
    id: "ttl.groupMembersMin",
    group: GROUP,
    label: "Group members",
    description:
      "Per-group member list. Local Add / Remove already invalidates the specific group, so this is purely about stale tolerance.",
    type: "number",
    defaultValue: 15,
    unit: "min",
    min: 1,
    max: 24 * 60,
    envVar: "VITE_TTL_GROUP_MEMBERS_MIN",
  }),
  wirelessCerts: defineSetting({
    id: "ttl.wirelessCertsMin",
    group: GROUP,
    label: "Wireless certs",
    description:
      "Vendor driver catalogs. Stale data shows instantly while a background refresh runs.",
    type: "number",
    defaultValue: 7 * 24 * 60,
    unit: "min",
    min: 1,
    max: 7 * 24 * 60,
    envVar: "VITE_TTL_WIRELESS_CERTS_MIN",
  }),
  computers: defineSetting({
    id: "ttl.computersMin",
    group: GROUP,
    label: "Computers",
    description: "Computer objects (Managed / Unmanaged / Admin / Admin Central).",
    type: "number",
    defaultValue: 30,
    unit: "min",
    min: 1,
    max: 24 * 60,
    envVar: "VITE_TTL_COMPUTERS_MIN",
  }),
  servers: defineSetting({
    id: "ttl.serversMin",
    group: GROUP,
    label: "Servers",
    description: "DE-blueprinted server hostnames -- practically static.",
    type: "number",
    defaultValue: 60,
    unit: "min",
    min: 1,
    max: 24 * 60,
    envVar: "VITE_TTL_SERVERS_MIN",
  }),
  tnbEligibleStaff: defineSetting({
    id: "ttl.tnbEligibleMin",
    group: GROUP,
    label: "Notebook fleet (NSSP)",
    description: "Refreshed server-side a few times per day; long TTLs are safe.",
    type: "number",
    defaultValue: 30,
    unit: "min",
    min: 1,
    max: 24 * 60,
    envVar: "VITE_TTL_TNB_ELIGIBLE_MIN",
  }),
  configStatic: defineSetting({
    id: "ttl.configMin",
    group: GROUP,
    label: "Static sidecar config",
    description: "E.g. the standard group suffix catalog.",
    type: "number",
    defaultValue: 120,
    unit: "min",
    min: 1,
    max: 24 * 60,
    envVar: "VITE_TTL_CONFIG_MIN",
  }),
  pxeBoot: defineSetting({
    id: "ttl.pxeBootMin",
    group: GROUP,
    label: "Netboot panel",
    description:
      "PXE boot library, layout, and service status. Panel polls every 8s while open; long TTL keeps sidebar switches instant.",
    type: "number",
    defaultValue: 30,
    unit: "min",
    min: 1,
    max: 24 * 60,
    envVar: "VITE_TTL_PXE_BOOT_MIN",
  }),
  mdmDevices: defineSetting({
    id: "ttl.mdmDevicesMin",
    group: GROUP,
    label: "MDM device inventory",
    description:
      "Jamf Pro / Jamf School / Mosyle / Mosyle Free device lists. Check-ins move slowly; Refresh always forces a fetch.",
    type: "number",
    defaultValue: 15,
    unit: "min",
    min: 1,
    max: 24 * 60,
    envVar: "VITE_TTL_MDM_DEVICES_MIN",
  }),
} as const;

export type TtlKey = keyof typeof SETTINGS;

/** Read-through Proxy: each access fetches the latest minutes value
 *  from the settings registry and multiplies into ms. */
export const TTL = new Proxy({} as Record<TtlKey, number>, {
  get(_target, key: string) {
    const def = (SETTINGS as Record<string, (typeof SETTINGS)[TtlKey]>)[key];
    if (!def) return undefined;
    return getSetting(def) * MS_PER_MIN;
  },
});

/** Devtools helper -- read effective TTLs. */
export function debugDumpTtls(): Record<TtlKey, string> {
  const out = {} as Record<TtlKey, string>;
  for (const k of Object.keys(SETTINGS) as TtlKey[]) {
    out[k] = `${TTL[k] / MS_PER_MIN} min`;
  }
  return out;
}
