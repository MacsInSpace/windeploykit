import type { InfraSshCredentialSummary } from "./types";

/** Login name for SSH / RDP / web UI — explicit loginName or label fallback. */
export function resolveInfraCredentialLoginName(
  cred: InfraSshCredentialSummary | undefined,
): string | undefined {
  if (!cred) return undefined;
  const login = cred.loginName?.trim();
  if (login) return login;
  const label = cred.label?.trim();
  return label || undefined;
}
