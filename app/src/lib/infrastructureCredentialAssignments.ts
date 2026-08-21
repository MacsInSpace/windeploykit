/** Per-site mapping from infrastructure device id → saved SSH credential id. */

const ASSIGNMENTS_KEY = "windeploykit.infrastructure.credentialAssignments.v1";

type SiteAssignments = Record<string, string>;
type AssignmentMap = Record<string, SiteAssignments>;

function readMap(): AssignmentMap {
  if (typeof localStorage === "undefined") return {};
  try {
    const raw = localStorage.getItem(ASSIGNMENTS_KEY);
    if (!raw) return {};
    return JSON.parse(raw) as AssignmentMap;
  } catch {
    return {};
  }
}

function writeMap(map: AssignmentMap): void {
  if (typeof localStorage === "undefined") return;
  try {
    if (Object.keys(map).length === 0) {
      localStorage.removeItem(ASSIGNMENTS_KEY);
    } else {
      localStorage.setItem(ASSIGNMENTS_KEY, JSON.stringify(map));
    }
  } catch {
    // non-fatal
  }
}

// Site ids are free-form (Site Profile owns the value), so the key is the trimmed
// id as-is. The previous implementation zero-padded to four digits, which only
// made sense for the numeric site ids this was extracted from.
function siteKey(siteId: string): string {
  return siteId.trim();
}

export function getCredentialAssignment(
  siteId: string,
  deviceId: string,
): string | undefined {
  const map = readMap();
  const id = map[siteKey(siteId)]?.[deviceId]?.trim();
  return id || undefined;
}

export function setCredentialAssignment(
  siteId: string,
  deviceId: string,
  credentialId: string | null | undefined,
): void {
  const map = readMap();
  const key = siteKey(siteId);
  const site = { ...(map[key] ?? {}) };
  const cred = credentialId?.trim();
  if (cred) {
    site[deviceId] = cred;
  } else {
    delete site[deviceId];
  }
  if (Object.keys(site).length === 0) {
    delete map[key];
  } else {
    map[key] = site;
  }
  writeMap(map);
}

/** Drop assignments pointing at a deleted vault entry (all sites). */
export function clearCredentialAssignmentsForId(credentialId: string): void {
  const target = credentialId.trim();
  if (!target) return;
  const map = readMap();
  let changed = false;
  for (const key of Object.keys(map)) {
    const site = map[key];
    const next: SiteAssignments = {};
    for (const [deviceId, credId] of Object.entries(site)) {
      if (credId === target) {
        changed = true;
      } else {
        next[deviceId] = credId;
      }
    }
    if (Object.keys(next).length === 0) {
      delete map[key];
    } else {
      map[key] = next;
    }
  }
  if (changed) writeMap(map);
}
