import type {
  PxeBootPluginConfigResponse,
  PxeBootPluginStatus,
  PxeBootWimLibraryResponse,
} from "./types";
import { getCached, setCached } from "./queryCache";
import { pushTrayTooltip } from "./tray";

/** In-memory cache key - survives Netboot panel unmount/remount. */
export const PXE_BOOT_CONFIG_CACHE_KEY = "pxe-boot:config";

export function getPxeBootPanelData(): PxeBootPluginConfigResponse | undefined {
  return getCached<PxeBootPluginConfigResponse>(PXE_BOOT_CONFIG_CACHE_KEY)?.data;
}

export function setPxeBootPanelData(data: PxeBootPluginConfigResponse): void {
  setCached(PXE_BOOT_CONFIG_CACHE_KEY, {
    status: "success",
    data,
    fetchedAt: Date.now(),
  });
  // Every status that lands here (load, Start, Stop, the housekeeping refresh) also
  // sets the tray tooltip, so it shows the serving URL without the panel being open.
  pushTrayTooltip(data.status);
}

export function patchPxeBootPanelData(
  patch: (prev: PxeBootPluginConfigResponse | undefined) => PxeBootPluginConfigResponse | undefined,
): void {
  const prev = getPxeBootPanelData();
  const next = patch(prev);
  if (next) setPxeBootPanelData(next);
}

export function mergePxeBootLibraryIntoPanelData(
  prev: PxeBootPluginConfigResponse | undefined,
  library: PxeBootWimLibraryResponse,
  options?: { retainStatus?: boolean },
): PxeBootPluginConfigResponse {
  const mergedLayout =
    options?.retainStatus && prev?.status?.layout
      ? {
          ...prev.status.layout,
          wims: library.layout.wims ?? prev.status.layout.wims,
          isos: library.layout.isos ?? prev.status.layout.isos,
          wimFiles: library.layout.wimFiles ?? prev.status.layout.wimFiles,
          isoFiles: library.layout.isoFiles ?? prev.status.layout.isoFiles,
          defaultBootWim:
            library.layout.defaultBootWim ??
            library.config.defaultBootWim ??
            prev.status.layout.defaultBootWim ??
            null,
        }
      : library.layout;

  const nextStatus: PxeBootPluginStatus | undefined =
    library.status ??
    (options?.retainStatus && prev?.status
      ? {
          ...prev.status,
          config: library.config,
          layout: mergedLayout,
          wims: library.wims ?? prev.status.wims,
          isos: library.isos ?? prev.status.isos,
          defaultBootWim: mergedLayout.defaultBootWim ?? library.config.defaultBootWim ?? null,
        }
      : library.status ?? prev?.status);

  if (!nextStatus) {
    return {
      config: library.config,
      layout: library.layout,
      status: library.status!,
    };
  }

  return {
    config: library.config,
    layout: mergedLayout,
    status: nextStatus,
  };
}

export function applyPxeBootLibraryToCache(
  library: PxeBootWimLibraryResponse,
  options?: { retainStatus?: boolean },
): void {
  setPxeBootPanelData(mergePxeBootLibraryIntoPanelData(getPxeBootPanelData(), library, options));
}

export function patchPxeBootPanelStatus(status: PxeBootPluginStatus): void {
  patchPxeBootPanelData((prev) =>
    prev
      ? {
          ...prev,
          config: status.config ? { ...prev.config, ...status.config } : prev.config,
          status,
        }
      : prev,
  );
}
