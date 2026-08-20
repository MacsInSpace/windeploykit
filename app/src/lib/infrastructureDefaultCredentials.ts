/** Built-in per-school infrastructure SSH credential ids (device vault). */

import {
  getCredentialAssignment,
  setCredentialAssignment,
} from "./infrastructureCredentialAssignments";
import { ADMIN_CORE_SWITCH_DEVICE_ID } from "./infrastructureSsh";

function padSchoolNumber(schoolNumber: string): string {
  return schoolNumber.padStart(4, "0");
}

export function defaultSchoolAdminCredId(schoolNumber: string): string {
  return `default-${padSchoolNumber(schoolNumber)}-school-admin`;
}

export function defaultWlcMonitorCredId(schoolNumber: string): string {
  return `default-${padSchoolNumber(schoolNumber)}-wlc-monitor`;
}

export function defaultSchoolAdminLabel(schoolNumber: string): string {
  return `${padSchoolNumber(schoolNumber)}SchoolAdmin`;
}

export function defaultWlcMonitorLabel(schoolNumber: string): string {
  return `${padSchoolNumber(schoolNumber)}WLCMonitor`;
}

const DEFAULT_CRED_ID =
  /^default-\d{4}-(?:school-admin|wlc-monitor)$/;

export function isDefaultInfraCredentialId(id: string): boolean {
  return DEFAULT_CRED_ID.test(id.trim());
}

/** Device ids that use SchoolAdmin vs WLCMonitor defaults. */
export const DEFAULT_SCHOOL_ADMIN_DEVICES = ["cs", ADMIN_CORE_SWITCH_DEVICE_ID, "es01", "es02"] as const;
export const DEFAULT_WLC_DEVICE = "wlc";
export const SITE_SWITCH_DEFAULT_ASSIGNMENT_ID = "__site-switch-default__";

/** Credential inherited by discovered/custom switches without an explicit assignment. */
export function getSiteSwitchDefaultCredentialId(schoolNumber: string): string {
  return getCredentialAssignment(schoolNumber, SITE_SWITCH_DEFAULT_ASSIGNMENT_ID)
    ?? defaultSchoolAdminCredId(schoolNumber);
}

export function setSiteSwitchDefaultCredentialId(
  schoolNumber: string,
  credentialId: string | null | undefined,
): void {
  setCredentialAssignment(schoolNumber, SITE_SWITCH_DEFAULT_ASSIGNMENT_ID, credentialId);
}

export function ensureDefaultCredentialAssignments(schoolNumber: string): void {
  for (const deviceId of DEFAULT_SCHOOL_ADMIN_DEVICES) {
    if (!getCredentialAssignment(schoolNumber, deviceId)) {
      setCredentialAssignment(schoolNumber, deviceId, defaultSchoolAdminCredId(schoolNumber));
    }
  }
  if (!getCredentialAssignment(schoolNumber, DEFAULT_WLC_DEVICE)) {
    setCredentialAssignment(
      schoolNumber,
      DEFAULT_WLC_DEVICE,
      defaultWlcMonitorCredId(schoolNumber),
    );
  }
}

export function sortCredentialsForSchool<T extends { id: string; isDefault?: boolean; builtIn?: boolean }>(
  credentials: T[],
  schoolNumber: string | undefined,
): T[] {
  if (!schoolNumber) return credentials;
  const adminId = defaultSchoolAdminCredId(schoolNumber);
  const wlcId = defaultWlcMonitorCredId(schoolNumber);
  const order = new Map([
    [adminId, 0],
    [wlcId, 1],
  ]);
  return [...credentials].sort((a, b) => {
    const ao = a.builtIn ? -1 : order.has(a.id) ? order.get(a.id)! : a.isDefault ? 2 : 10;
    const bo = b.builtIn ? -1 : order.has(b.id) ? order.get(b.id)! : b.isDefault ? 2 : 10;
    if (ao !== bo) return ao - bo;
    return a.id.localeCompare(b.id);
  });
}

export function filterCredentialsForSchool<T extends { id: string; schoolNumber?: string; builtIn?: boolean }>(
  credentials: T[],
  schoolNumber: string | undefined,
): T[] {
  if (!schoolNumber) return [];
  const sn = padSchoolNumber(schoolNumber);
  return credentials.filter((c) => {
    // App-provided virtual entries (signed-in DE account) are school-agnostic.
    if (c.builtIn) return true;
    if (c.schoolNumber) return c.schoolNumber.padStart(4, "0") === sn;
    if (isDefaultInfraCredentialId(c.id)) {
      return c.id.startsWith(`default-${sn}-`);
    }
    return false;
  });
}

export function schoolDefaultCredentials<T extends { id: string; isDefault?: boolean }>(
  credentials: T[],
  schoolNumber: string | undefined,
): T[] {
  return filterCredentialsForSchool(credentials, schoolNumber).filter(
    (c) => c.isDefault || isDefaultInfraCredentialId(c.id),
  );
}
