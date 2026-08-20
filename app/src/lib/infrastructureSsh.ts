import type { InfrastructureProbeRow } from "./infrastructureProbeTypes";

/** Built-in admin VLAN 100 core switch (catalogue .9 — Cisco 2960-X 24p). */
export const ADMIN_CORE_SWITCH_DEVICE_ID = "acs";

/** Admin network printer — default .64 on admin subnet (IP often site-specific). */
export const ADMIN_PRINTER_DEVICE_ID = "aprinter";

/** Catalogue admin three octets when school admin subnet is unknown (VLAN 100). */
export const ADMIN_NETWORK_CATALOGUE_THREE_OCTETS = "10.165.207";

function padSchoolNumber(schoolNumber: string): string {
  return schoolNumber.padStart(4, "0");
}

/** Curric core / distribution switch local login (e.g. 5573SchoolAdmin). */
export function schoolSwitchSshUsername(schoolNumber: string): string {
  return `${padSchoolNumber(schoolNumber)}SchoolAdmin`;
}

/** WLC read-only web login (e.g. 5573WLCMonitor). */
export function schoolWlcMonitorUsername(schoolNumber: string): string {
  return `${padSchoolNumber(schoolNumber)}WLCMonitor`;
}

/** Built-in core, admin core, optional ES, and custom switches use SchoolAdmin-style SSH. */
export function rowSupportsSchoolSwitchSsh(row: Pick<InfrastructureProbeRow, "id">): boolean {
  return (
    row.id === "cs" ||
    row.id === ADMIN_CORE_SWITCH_DEVICE_ID ||
    row.id === "es01" ||
    row.id === "es02" ||
    row.id.startsWith("custom-")
  );
}

/** Built-in WLC row — monitor login on curric .5 (SSH + HTTP). */
export function rowSupportsWlcMonitor(row: Pick<InfrastructureProbeRow, "id">): boolean {
  return row.id === "wlc";
}

/** @deprecated use rowSupportsWlcMonitor */
export const rowSupportsWlcMonitorWeb = rowSupportsWlcMonitor;

export function isValidManagementIpv4(value: string): boolean {
  const parts = value.trim().split(".");
  return parts.length === 4 && parts.every((part) => {
    if (!/^\d{1,3}$/.test(part)) return false;
    const number = Number(part);
    return number >= 0 && number <= 255 && String(number) === part;
  });
}

export function gearTargetAddress(row: InfrastructureProbeRow): string | undefined {
  if (row.managementAddressRequired) return undefined;
  const ip = row.ip?.trim();
  if (ip) return ip;
  const host = row.hostname?.trim();
  if (host) return host;
  return row.address?.trim() || undefined;
}

/** @deprecated use gearTargetAddress */
export const sshTargetAddress = gearTargetAddress;

/** HTTPS URL for WLC monitor login (curric .5 — no http→https redirect). */
export function wlcMonitorWebUrl(row: InfrastructureProbeRow): string | undefined {
  const host = gearTargetAddress(row);
  if (!host) return undefined;
  if (/^https:\/\//i.test(host)) return host;
  if (/^http:\/\//i.test(host)) return host.replace(/^http:\/\//i, "https://");
  return `https://${host}`;
}

/** HTTPS-only IOS-XE web UI on curric core switch (e.g. https://10.122.192.1/webui/). */
export function schoolSwitchWebUrl(row: InfrastructureProbeRow): string | undefined {
  const host = gearTargetAddress(row);
  if (!host) return undefined;
  const bare = host.replace(/^https?:\/\//i, "").replace(/\/.*$/, "");
  return `https://${bare}/webui/`;
}

/** Built-in curric and admin core switch rows (HTTPS web UI). */
export function rowSupportsCoreSwitchWeb(row: Pick<InfrastructureProbeRow, "id">): boolean {
  return row.id === "cs" || row.id === ADMIN_CORE_SWITCH_DEVICE_ID;
}

/** Admin printer + custom printers — HTTP status / config page (no SSH). */
export function rowSupportsAdminPrinterWeb(row: Pick<InfrastructureProbeRow, "id">): boolean {
  return row.id === ADMIN_PRINTER_DEVICE_ID || row.id.startsWith("printer-");
}

export function adminPrinterWebUrl(ip: string): string {
  const bare = ip.trim().replace(/^https?:\/\//i, "").replace(/\/.*$/, "");
  return `http://${bare}`;
}
