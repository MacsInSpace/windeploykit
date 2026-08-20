import type { InfrastructureProbeKind, InfrastructureProbeResult } from "./types";

export type InfrastructureProbeStatus =
  | "idle"
  | "probing"
  | "up"
  | "flaky"
  | "down"
  | "error";

export interface InfrastructureProbeRow {
  id: string;
  role: string;
  probeKind?: InfrastructureProbeKind;
  ip?: string;
  url?: string;
  hostname?: string;
  port?: number;
  address?: string;
  siteOptional?: boolean;
  /** Configuration record is intentionally incomplete until an operator enters its management IP. */
  managementAddressRequired?: boolean;
  /** Non-selectable template row (custom servers tab). */
  isExample?: boolean;
  reachability: InfrastructureProbeStatus;
  replies?: number;
  attempts?: number;
  detail?: string;
  testing?: boolean;
}

/** One ICMP packet per attempt; always run all attempts (no stop-on-first-success). */
export const PROBE_MAX_ATTEMPTS = 5;
/**
 * Replies we may lose and still call a link up (so 4/5 is up, 3/5 is flaky).
 * Switches, routers and WLCs deprioritise ICMP to their own control plane, so a healthy
 * device under load drops the occasional ping while forwarding traffic fine — at 3
 * attempts a single such drop made solid infrastructure read as flaky. Two drops is not
 * explained by that, so it still shows as flaky rather than being tuned away.
 */
export const PROBE_ALLOWED_LOSS = 1;
export const PROBE_STAGGER_MS = 300;
/** Central HTTP/TCP probes — fail fast when DNS or TLS hangs (app panels only). */
export const PROBE_HTTP_TIMEOUT_SEC = 1;
export const PROBE_TCP_TIMEOUT_SEC = 1;

export function mapProbeResultStatus(
  result: InfrastructureProbeResult,
  probing: boolean,
): InfrastructureProbeStatus {
  if (probing) return "probing";
  if (result.status === "up") return "up";
  if (result.status === "flaky") return "flaky";
  return "down";
}

export function centralProbeInvokeParams(
  row: InfrastructureProbeRow,
  maxAttempts: number = PROBE_MAX_ATTEMPTS,
) {
  const kind = row.probeKind ?? "http";
  const timeoutSec =
    kind === "http"
      ? PROBE_HTTP_TIMEOUT_SEC
      : kind === "tcp"
        ? PROBE_TCP_TIMEOUT_SEC
        : undefined;
  return {
    kind,
    target: kind === "icmp" ? row.ip ?? row.hostname ?? row.address : undefined,
    url: kind === "http" ? row.url : undefined,
    host: kind === "tcp" ? row.hostname : undefined,
    port: row.port,
    fullTest: true,
    maxAttempts,
    allowedLoss: PROBE_ALLOWED_LOSS,
    timeoutSec,
  };
}

export function serverRowProbeTarget(row: {
  IPAddress?: string;
  DnsHostName?: string;
  Name?: string;
}): { ip?: string; hostname?: string } | null {
  if (row.IPAddress?.trim()) return { ip: row.IPAddress.trim() };
  if (row.DnsHostName?.trim()) return { hostname: row.DnsHostName.trim() };
  if (row.Name?.trim()) return { hostname: row.Name.trim() };
  return null;
}
