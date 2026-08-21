/** Site-scoped infrastructure SSH credential helpers (device vault). */

import {
  getCredentialAssignment,
  setCredentialAssignment,
} from "./infrastructureCredentialAssignments";

// Vault ids created by the app itself, as opposed to ones the technician named.
// The `default-<site>-admin` shape is what the credential list sorts to the top.
const DEFAULT_CRED_ID = /^default-.+-admin$/;

export function defaultSiteAdminCredId(siteId: string): string {
  return `default-${siteId.trim()}-admin`;
}

export function isDefaultInfraCredentialId(id: string): boolean {
  return DEFAULT_CRED_ID.test(id.trim());
}

/** Credential inherited by devices without an explicit assignment. */
export const SITE_DEFAULT_ASSIGNMENT_ID = "__site-default__";

export function getSiteDefaultCredentialId(siteId: string): string {
  return getCredentialAssignment(siteId, SITE_DEFAULT_ASSIGNMENT_ID)
    ?? defaultSiteAdminCredId(siteId);
}

export function setSiteDefaultCredentialId(
  siteId: string,
  credentialId: string | null | undefined,
): void {
  setCredentialAssignment(siteId, SITE_DEFAULT_ASSIGNMENT_ID, credentialId);
}

export function sortCredentialsForSite<T extends { id: string; isDefault?: boolean; builtIn?: boolean }>(
  credentials: T[],
  siteId: string | undefined,
): T[] {
  if (!siteId) return credentials;
  const adminId = defaultSiteAdminCredId(siteId);
  return [...credentials].sort((a, b) => {
    const rank = (c: T) => (c.builtIn ? -1 : c.id === adminId ? 0 : c.isDefault ? 2 : 10);
    const ao = rank(a);
    const bo = rank(b);
    if (ao !== bo) return ao - bo;
    return a.id.localeCompare(b.id);
  });
}

export function filterCredentialsForSite<T extends { id: string; siteId?: string; builtIn?: boolean }>(
  credentials: T[],
  siteId: string | undefined,
): T[] {
  if (!siteId) return [];
  const site = siteId.trim();
  return credentials.filter((c) => {
    // App-provided virtual entries are site-agnostic.
    if (c.builtIn) return true;
    if (c.siteId) return c.siteId.trim() === site;
    if (isDefaultInfraCredentialId(c.id)) {
      return c.id.startsWith(`default-${site}-`);
    }
    return false;
  });
}

export function siteDefaultCredentials<T extends { id: string; isDefault?: boolean }>(
  credentials: T[],
  siteId: string | undefined,
): T[] {
  return filterCredentialsForSite(credentials, siteId).filter(
    (c) => c.isDefault || isDefaultInfraCredentialId(c.id),
  );
}
