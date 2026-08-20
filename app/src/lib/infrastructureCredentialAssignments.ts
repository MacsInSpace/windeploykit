/** Per-school mapping from infrastructure probe id → saved SSH credential id. */

const ASSIGNMENTS_KEY = "windeploykit.infrastructure.credentialAssignments.v1";

type SchoolAssignments = Record<string, string>;
type AssignmentMap = Record<string, SchoolAssignments>;

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

function schoolKey(schoolNumber: string): string {
  return schoolNumber.padStart(4, "0");
}

export function getCredentialAssignment(
  schoolNumber: string,
  deviceId: string,
): string | undefined {
  const map = readMap();
  const id = map[schoolKey(schoolNumber)]?.[deviceId]?.trim();
  return id || undefined;
}

export function setCredentialAssignment(
  schoolNumber: string,
  deviceId: string,
  credentialId: string | null | undefined,
): void {
  const map = readMap();
  const key = schoolKey(schoolNumber);
  const school = { ...(map[key] ?? {}) };
  const cred = credentialId?.trim();
  if (cred) {
    school[deviceId] = cred;
  } else {
    delete school[deviceId];
  }
  if (Object.keys(school).length === 0) {
    delete map[key];
  } else {
    map[key] = school;
  }
  writeMap(map);
}

/** Drop assignments pointing at a deleted vault entry (all schools). */
export function clearCredentialAssignmentsForId(credentialId: string): void {
  const target = credentialId.trim();
  if (!target) return;
  const map = readMap();
  let changed = false;
  for (const sn of Object.keys(map)) {
    const school = map[sn];
    const next: SchoolAssignments = {};
    for (const [deviceId, credId] of Object.entries(school)) {
      if (credId === target) {
        changed = true;
      } else {
        next[deviceId] = credId;
      }
    }
    if (Object.keys(next).length === 0) {
      delete map[sn];
    } else {
      map[sn] = next;
    }
  }
  if (changed) writeMap(map);
}
