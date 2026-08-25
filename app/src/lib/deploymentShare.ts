/**
 * "Update Deployment Share" - MDT's verb, ours regenerates everything the services
 * serve without stopping anything (sidecar Update-AppPxeBootDeploymentShare). Shared
 * by the Netboot node and the share root so both verbs behave identically; each
 * panel owns only its busy flag.
 */
import { sidecar } from "./ipc";
import type { PxeBootDeploymentShareUpdateResult } from "./types";
import { toast } from "../state/toastStore";

const TITLE = "Update Deployment Share";

function plural(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`;
}

/** Runs the update and reports it; resolves to the result, or null when it failed (already toasted). */
export async function updateDeploymentShare(): Promise<PxeBootDeploymentShareUpdateResult | null> {
  try {
    // No status in the result on purpose: the caller refetches (Netboot's reloadConfig,
    // the share root's 8 s poll), and the probe was over half the call's time.
    const r = await sidecar.invoke<PxeBootDeploymentShareUpdateResult>("UpdatePxeBootDeploymentShare");

    const parts = [
      `boot menu + ${plural(r.taskSequencesPublished, "task sequence", "task sequences")}`,
      r.deployUnc ? `deploy overlay (${r.deployUnc})` : "deploy overlay",
    ];
    if (r.servicesRunning) {
      parts.push(r.shareActive ? "Deploy$ shared" : r.shareEnabled ? "Deploy$ not published" : "Deploy$ off");
      parts.push(plural(r.isoMounts, "ISO mount", "ISO mounts"));
    }
    const tail = r.servicesRunning ? "" : " Services are stopped - Start Services to serve them.";
    toast.info(TITLE, `${parts.join(", ")} regenerated in ${(r.elapsedMs / 1000).toFixed(1)} s.${tail}`);

    if (r.restartReasons.length > 0) {
      toast.warn("Restart Services to finish", r.restartReasons.join(" "));
    }
    for (const w of r.warnings) toast.warn(TITLE, w);
    return r;
  } catch (e) {
    toast.error(TITLE, e instanceof Error ? e.message : String(e));
    return null;
  }
}
