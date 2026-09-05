import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";
import { readFile } from "@tauri-apps/plugin-fs";
import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";

import { DataTable, type DataTableColumn } from "../components/DataTable";
import { PanelShell } from "../components/PanelShell";
import { SEP, type MenuItem } from "../components/ContextMenu";
import { useConsoleActions, type ConsoleNodeActions } from "../state/consoleActions";
import { getConfiguredDownloadBaseDir } from "../lib/downloadPath";
import {
  formatImageLibraryRootPreview,
  getImageLibraryFreeSpace,
  getImageLibraryRoot,
} from "../lib/imageLibrary";
import { bytesToBase64 } from "../lib/bytesToBase64";
import { onSidecarEvent, sidecar } from "../lib/ipc";
import type {
  AcerSccmCatalogHarvestResponse,
  Aria2DownloadRow,
  Aria2DownloadsPayload,
  Aria2ExtensionRoute,
  Aria2PluginConfig,
  Aria2TrackerCatalog,
  Aria2TrackerDriverRow,
  Aria2TrackerOemIsoRow,
  PxeBootIsoEntry,
  PxeBootLinuxNetbootEntry,
  PxeBootLinuxNetbootResponse,
  EvalIsoCatalogResponse,
  EvalIsoDownloadAllResponse,
  EvalIsoEntry,
  EvalIsoRefreshResponse,
  VendorSccmCatalogRefreshResponse,
} from "../lib/types";
import { toast } from "../state/toastStore";

const POLL_MS = 2000;

type TabId = "images" | "drivers" | "add" | "settings";
type AssetKind = "auto" | "iso" | "wim" | "driver" | "other";
type DriversView = "acer" | "lenovo" | "dell" | "hp" | "microsoft";

function acerCatalogFamilyLabel(family?: string | null): string {
  switch (family) {
    case "p2xx":
      return "P2";
    case "p4xx":
      return "P4";
    case "p6xx":
      return "P6";
    case "legacy-p":
      return "Legacy P";
    case "b1xx":
      return "B1";
    case "b3xx":
      return "B3";
    case "x3xx":
      return "X3";
    case "b514":
      return "B514";
    case "x514":
      return "X514";
    default:
      return family ?? "-";
  }
}


function dellCatalogFamilyLabel(family?: string | null): string {
  if (!family) return "-";
  return family.charAt(0).toUpperCase() + family.slice(1);
}


function microsoftCatalogFamilyLabel(family?: string | null): string {
  switch (family) {
    case "surface-pro":
      return "Pro";
    case "surface-laptop":
      return "Laptop";
    case "surface-go":
      return "Go";
    case "surface-book":
      return "Book";
    case "surface-studio":
      return "Studio/Hub";
    default:
      return family ?? "-";
  }
}


function hpCatalogFamilyLabel(family?: string | null): string {
  switch (family) {
    case "notebooks":
      return "Notebook";
    case "desktops":
      return "Desktop";
    case "workstations":
      return "Workstation";
    case "thin-clients":
      return "Thin client";
    default:
      return family ?? "-";
  }
}


async function aria2SidecarParams(extra?: Record<string, unknown>) {
  const downloadDir = await getConfiguredDownloadBaseDir();
  const imageLibraryRoot = await getImageLibraryRoot();
  return {
    ...(downloadDir ? { downloadDir } : {}),
    ...(imageLibraryRoot ? { imageLibraryRoot } : {}),
    ...extra,
  };
}

function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return "-";
  if (n >= 1024 ** 3) return `${(n / 1024 ** 3).toFixed(1)} GB`;
  if (n >= 1024 ** 2) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  if (n >= 1024) return `${Math.round(n / 1024)} KB`;
  return `${n} B`;
}

function formatSpeed(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return "-";
  return `${formatBytes(n)}/s`;
}

function basename(path?: string | null): string {
  if (!path) return "-";
  const parts = path.split(/[/\\]/);
  return parts[parts.length - 1] || path;
}

function tabBtn(active: boolean): CSSProperties {
  return {
    padding: "4px 10px",
    fontSize: 11,
    borderBottom: active ? "2px solid var(--accent)" : "2px solid transparent",
    color: active ? "var(--text)" : "var(--text2)",
    background: "transparent",
    cursor: "pointer",
  };
}

function formatPeerCount(n?: number | null): string {
  if (n == null || !Number.isFinite(n)) return "-";
  return String(n);
}

function isHttpUrl(url?: string | null): boolean {
  return Boolean(url && /^https?:\/\//i.test(url.trim()));
}

function driverDownloadNeedsAria2(row: Aria2TrackerDriverRow): boolean {
  if (row.magnet) return true;
  return !isHttpUrl(row.uri);
}

function driverTrackerRowKey(row: Aria2TrackerDriverRow): string {
  return `${row.vendor}|${row.folder}`;
}

function driverTrackerRowLabel(row: Aria2TrackerDriverRow): string {
  return row.modelName ?? row.folder;
}

function isDirectDriverHttpDownload(params: {
  assetKind?: AssetKind;
  uris?: string[];
}): boolean {
  return (
    params.assetKind === "driver" &&
    Boolean(params.uris?.some((uri) => isHttpUrl(uri)))
  );
}

/**
 * Content acquisition. Mounted three ways, one per MDT node:
 *   tabs=["drivers"]           -> Out-of-Box Drivers
 *   tabs=["images"]            -> Operating Systems
 *   default (all)              -> Transfers
 */
export function ContentWorkspace({
  tabs,
  title,
}: {
  tabs?: readonly TabId[];
  title?: string;
} = {}) {
  const visibleTabs: readonly TabId[] = tabs ?? (["images", "drivers", "add", "settings"] as const);
  const [tab, setTab] = useState<TabId>(visibleTabs[0] ?? "images");
  const [config, setConfig] = useState<Aria2PluginConfig | null>(null);
  const [downloads, setDownloads] = useState<Aria2DownloadsPayload | null>(null);
  const [tracker, setTracker] = useState<Aria2TrackerCatalog | null>(null);
  const [uriInput, setUriInput] = useState("");
  const [assetKind, setAssetKind] = useState<AssetKind>("auto");
  const [modelAlias, setModelAlias] = useState("");
  const [extensionRoutes, setExtensionRoutes] = useState<Aria2ExtensionRoute[]>([]);
  const [imagesFilter, setImagesFilter] = useState("");
  const [driversFilter, setDriversFilter] = useState("");
  const [driversView, setDriversView] = useState<DriversView>("acer");
  const [loadingConfig, setLoadingConfig] = useState(false);
  const [daemonBusy, setDaemonBusy] = useState(false);
  const [installBusy, setInstallBusy] = useState(false);
  const [adding, setAdding] = useState(false);
  // Active direct pack downloads, keyed by row key ({0,0} = connecting). Several
  // can run at once - each has its own sidecar runspace. A failed entry stays,
  // flagged, until the user retries (no auto-retry - the sidecar already purged
  // the bad file so the row can never read as Downloaded).
  const [driverDownloads, setDriverDownloads] = useState<
    Record<string, { bytesDone: number; totalBytes: number; failed?: boolean; message?: string; queued?: boolean }>
  >({});
  // Row labels for completion/failure toasts (events carry only key + fileName).
  const driverLabelsRef = useRef<Record<string, string>>({});
  const [catalogRefreshBusy, setCatalogRefreshBusy] = useState(false);
  // Microsoft Evaluation Center media. Cached catalog (14 days) - the sidecar never
  // scrapes on the dispatch thread, so this is just a read of the cache plus disk state.
  const [evalIso, setEvalIso] = useState<EvalIsoCatalogResponse | null>(null);
  const [evalIsoBusy, setEvalIsoBusy] = useState(false);
  // What is actually in the ISO store: downloaded evaluation media and anything imported
  // by hand. This is the list that answers "where did my ISO go".
  const [storeIsos, setStoreIsos] = useState<PxeBootIsoEntry[]>([]);
  // Debian network installers: no ISO, kernel + initrd from the mirror kept in the store.
  const [linuxNetboot, setLinuxNetboot] = useState<PxeBootLinuxNetbootResponse | null>(null);
  const [linuxNetbootBusy, setLinuxNetbootBusy] = useState<string | null>(null);
  const [isoBusy, setIsoBusy] = useState(false);
  const [imageRootPreview, setImageRootPreview] = useState("");
  const [imageFreeBytes, setImageFreeBytes] = useState<number | null>(null);
  const pollRef = useRef<number | null>(null);

  const loadConfig = useCallback(async () => {
    setLoadingConfig(true);
    try {
      const data = await sidecar.invoke<Aria2PluginConfig>(
        "GetAria2PluginConfig",
        await aria2SidecarParams(),
      );
      setConfig(data);
      setExtensionRoutes(data.extensionRoutes ?? []);
    } catch (e) {
      toast.error("aria2", e instanceof Error ? e.message : String(e));
    } finally {
      setLoadingConfig(false);
    }
  }, []);

  /** "Catalogs checked 3 days ago" from the oldest vendor fetch time (stale-while-revalidate: rows never blank). */
  const catalogCheckedLabel = useMemo(() => {
    const stamps = [
      tracker?.acerCatalogAt,
      tracker?.lenovoCatalogAt,
      tracker?.dellCatalogAt,
      tracker?.hpCatalogAt,
      tracker?.microsoftCatalogAt,
    ]
      .map((s) => (s ? Date.parse(s) : NaN))
      .filter((n) => Number.isFinite(n));
    if (stamps.length === 0) return "Catalogs: bundled copy (never checked online) - checked automatically every 2 weeks";
    const oldest = Math.min(...stamps);
    const days = Math.floor((Date.now() - oldest) / 86_400_000);
    const when = days <= 0 ? "today" : days === 1 ? "yesterday" : `${days} days ago`;
    const next = Math.max(0, 14 - days);
    return `Catalogs checked ${when} - next automatic check ${next === 0 ? "at the next opportunity" : `in ${next} day${next === 1 ? "" : "s"}`}`;
  }, [tracker]);

  const loadTracker = useCallback(async () => {
    try {
      const data = await sidecar.invoke<Aria2TrackerCatalog>("GetAria2TrackerCatalog");
      setTracker(data);
    } catch (e) {
      toast.error("aria2 tracker", e instanceof Error ? e.message : String(e));
    }
  }, []);

  const loadEvalIso = useCallback(async () => {
    try {
      const data = await sidecar.invoke<EvalIsoCatalogResponse>(
        "GetEvalIsoCatalog",
        await aria2SidecarParams(),
      );
      setEvalIso(data);
    } catch (e) {
      toast.error("Windows media", e instanceof Error ? e.message : String(e));
    }
  }, []);

  const loadStoreIsos = useCallback(async () => {
    try {
      // ListPxeBootIsos, not GetPxeBootPluginStatus: the full status costs ~2.6 s
      // (process probes, mounts, adapters) where the inventory alone is ~3 ms.
      const data = await sidecar.invoke<{ isos?: PxeBootIsoEntry[] }>("ListPxeBootIsos", await aria2SidecarParams());
      setStoreIsos(data?.isos ?? []);
    } catch {
      /* Netboot plug-in may be off - the section just stays empty */
    }
  }, []);

  const importIso = useCallback(async () => {
    const picked = await open({
      multiple: false,
      filters: [{ name: "Disc image", extensions: ["iso"] }],
    });
    if (!picked || typeof picked !== "string") return;
    setIsoBusy(true);
    try {
      await sidecar.invoke("ImportPxeBootIso", { sourcePath: picked, replaceExisting: true });
      toast.success("ISO library", `${picked.split(/[/\\]/).pop()} imported.`);
      await loadStoreIsos();
      void loadEvalIso();
    } catch (e) {
      toast.error("ISO library", e instanceof Error ? e.message : String(e));
    } finally {
      setIsoBusy(false);
    }
  }, [loadStoreIsos]);

  const removeIso = useCallback(
    async (row: PxeBootIsoEntry) => {
      setIsoBusy(true);
      try {
        await sidecar.invoke("RemovePxeBootIso", { fileName: row.fileName });
        toast.info("ISO library", `${row.fileName} removed.`);
        await loadStoreIsos();
        void loadEvalIso();
      } catch (e) {
        toast.error("ISO library", e instanceof Error ? e.message : String(e));
      } finally {
        setIsoBusy(false);
      }
    },
    [loadStoreIsos],
  );

  const loadLinuxNetboot = useCallback(async () => {
    try {
      const data = await sidecar.invoke<PxeBootLinuxNetbootResponse>("ListPxeBootLinuxNetboot", await aria2SidecarParams());
      setLinuxNetboot(data ?? null);
    } catch (e) {
      toast.error("Linux installers", e instanceof Error ? e.message : String(e));
    }
  }, []);

  // Add fetches the current netboot kernel + initrd (about 95 MB) from the Debian mirror
  // and verifies them against its SHA256SUMS; the PXE menu gets the entry on return.
  const addLinuxNetboot = useCallback(
    async (row: PxeBootLinuxNetbootEntry) => {
      setLinuxNetbootBusy(row.id);
      try {
        toast.info("Linux installers", `Fetching ${row.label} ${row.arch} netboot files from the Debian mirror...`);
        const data = await sidecar.invoke<PxeBootLinuxNetbootResponse & { updated?: boolean }>(
          "AddPxeBootLinuxNetboot",
          await aria2SidecarParams({ codename: row.codename, arch: row.arch }),
        );
        setLinuxNetboot(data ?? null);
        toast.success(
          "Linux installers",
          data?.updated ? `${row.label} ${row.arch} is on the PXE menu.` : `${row.label} ${row.arch} was already current.`,
        );
      } catch (e) {
        toast.error("Linux installers", e instanceof Error ? e.message : String(e));
      } finally {
        setLinuxNetbootBusy(null);
      }
    },
    [],
  );

  const removeLinuxNetboot = useCallback(
    async (row: PxeBootLinuxNetbootEntry) => {
      setLinuxNetbootBusy(row.id);
      try {
        const data = await sidecar.invoke<PxeBootLinuxNetbootResponse>(
          "RemovePxeBootLinuxNetboot",
          await aria2SidecarParams({ codename: row.codename, arch: row.arch }),
        );
        setLinuxNetboot(data ?? null);
        toast.info("Linux installers", `${row.label} ${row.arch} removed from the PXE menu.`);
      } catch (e) {
        toast.error("Linux installers", e instanceof Error ? e.message : String(e));
      } finally {
        setLinuxNetbootBusy(null);
      }
    },
    [],
  );

  const refreshEvalIso = useCallback(async () => {
    setEvalIsoBusy(true);
    try {
      const res = await sidecar.invoke<EvalIsoRefreshResponse>(
        "RefreshEvalIsoCatalog",
        await aria2SidecarParams(),
      );
      if (res?.alreadyRunning) {
        toast.info("Windows media", "A catalog check is already running.");
      } else {
        toast.info("Windows media", "Checking Microsoft for current evaluation media...");
      }
    } catch (e) {
      setEvalIsoBusy(false);
      toast.error("Windows media", e instanceof Error ? e.message : String(e));
    }
  }, []);

  const downloadEvalIso = useCallback(
    async (row: EvalIsoEntry) => {
      const key = `eval|${row.id}`;
      driverLabelsRef.current[key] = `${row.productName}${row.edition === "LTSC" ? " LTSC" : ""}`;
      setDriverDownloads((prev) => ({ ...prev, [key]: { bytesDone: 0, totalBytes: 0 } }));
      try {
        await sidecar.invoke("StartEvalIsoDownload", await aria2SidecarParams({ id: row.id }));
      } catch (e) {
        setDriverDownloads((prev) => {
          const next = { ...prev };
          delete next[key];
          return next;
        });
        toast.error("Windows media", e instanceof Error ? e.message : String(e));
      }
    },
    [],
  );

  const downloadAllEvalIso = useCallback(async () => {
    const pending = (evalIso?.entries ?? []).filter((r) => !r.downloaded && r.url);
    if (pending.length === 0) return;
    setEvalIsoBusy(true);
    try {
      // Sequential on the sidecar side - six multi-GB streams at once finish nothing.
      for (const row of pending) {
        driverLabelsRef.current[`eval|${row.id}`] =
          `${row.productName}${row.edition === "LTSC" ? " LTSC" : ""}`;
      }
      setDriverDownloads((prev) => ({
        ...prev,
        [`eval|${pending[0].id}`]: { bytesDone: 0, totalBytes: 0 },
      }));
      const res = await sidecar.invoke<EvalIsoDownloadAllResponse>(
        "StartEvalIsoDownloadAll",
        await aria2SidecarParams(),
      );
      if (res?.message) {
        toast.info("Windows media", res.message);
      } else {
        toast.info(
          "Windows media",
          `Downloading ${(res?.started ?? 0) + (res?.queued ?? 0)} ISO(s) one at a time${
            res?.totalBytes ? ` (${formatBytes(res.totalBytes)})` : ""
          }.`,
        );
      }
    } catch (e) {
      toast.error("Windows media", e instanceof Error ? e.message : String(e));
    } finally {
      setEvalIsoBusy(false);
    }
  }, [evalIso]);

  const refreshDownloads = useCallback(async () => {
    try {
      const data = await sidecar.invoke<Aria2DownloadsPayload>("GetAria2Downloads");
      setDownloads(data);
    } catch {
      /* daemon may be stopped */
    }
  }, []);

  /**
   * USM-side vendor catalog refresh - all four vendors, one action (replaces the retired
   * CI job). Dell/HP/Lenovo refresh via sidecar curl; Acer needs a real browser
   * engine (its discovery pages fingerprint-block curl from any network), so a hidden app
   * webview harvests the community-KB links and the sidecar validates + stores them.
   */
  const refreshVendorCatalogs = useCallback(async () => {
    setCatalogRefreshBusy(true);
    try {
      // Background child pwsh in the sidecar - the call returns immediately and
      // the 'vendor-catalog-refresh' event finishes the flow (busy stays on).
      const res = await sidecar.invoke<{ accepted?: boolean; alreadyRunning?: boolean }>(
        "RefreshVendorSccmCatalogs",
      );
      if (res?.alreadyRunning) {
        toast.info("Vendor catalogs", "A refresh is already running - hang tight.");
      }
    } catch (e) {
      toast.error("Vendor catalogs", e instanceof Error ? e.message : String(e));
      setCatalogRefreshBusy(false);
    }
  }, []);

  /** Completion path for the background refresh (the 'vendor-catalog-refresh' event). */
  const finishVendorCatalogRefresh = useCallback(
    async (res: VendorSccmCatalogRefreshResponse & { error?: string }) => {
      try {
        if (res.automatic) {
          // Sidecar's two-week check: swap the rows in quietly. No toasts, and never the
          // Acer browser harvest - that only runs when the technician asked for a refresh.
          if (!res.error) await loadTracker();
          return;
        }
        if (res.error) {
          toast.error("Vendor catalogs", res.error);
          return;
        }
        const parts = (res.results ?? []).map((r) =>
          r.ok ? `${r.vendor} ${r.count}${r.belowFloor ? " (low!)" : ""}` : `${r.vendor} FAILED`,
        );
        // Acer refreshes over curl like the rest (AcerCatalog.xml). The webview KB
        // harvest only runs as a coverage top-up: XML fetch failed, or the last full
        // harvest is missing / older than 60 days (the XML has no B/X-series or legacy).
        // The harvest window runs VISIBLE: macOS suspends timers in occluded WKWebViews,
        // so a hidden window never solves the Cloudflare challenge (field-proven). It
        // titles itself and closes automatically when the links are captured.
        let acerPart = "";
        let harvestFailed = false;
        if (res.acerHarvestRecommended && res.acerHarvestUrl) {
          try {
            const urls = await invoke<string[]>("harvest_acer_sccm_urls", {
              url: res.acerHarvestUrl,
              timeoutSecs: 90,
              visible: true,
            });
            const acer = await sidecar.invoke<AcerSccmCatalogHarvestResponse>("SubmitAcerSccmCatalogHarvest", {
              urls,
              harvestedFrom: res.acerHarvestUrl,
            });
            acerPart = `, acer harvest ${acer.urlCount}`;
          } catch (err) {
            harvestFailed = true;
            acerPart = ", acer harvest failed";
            toast.warn("Acer coverage harvest", err instanceof Error ? err.message : String(err));
          }
        }
        const failures = (res.results ?? []).filter((r) => !r.ok).length;
        const summary = `${parts.join(", ")}${acerPart}`;
        if (failures > 0) {
          toast.error("Vendor catalogs", summary);
        } else if (harvestFailed) {
          // All five catalogs refreshed - only the optional B/X-series top-up failed.
          toast.warn("Vendor catalogs refreshed", summary);
        } else {
          toast.success("Vendor catalogs refreshed", summary);
        }
        await loadTracker();
      } finally {
        setCatalogRefreshBusy(false);
      }
    },
    [loadTracker],
  );

  const refreshImageDestination = useCallback(async () => {
    setImageRootPreview(await formatImageLibraryRootPreview());
    const info = await getImageLibraryFreeSpace();
    setImageFreeBytes(info?.ok ? info.freeBytes : null);
  }, []);

  useEffect(() => {
    void loadConfig();
    void loadTracker();
    void loadEvalIso();
    void loadStoreIsos();
    void loadLinuxNetboot();
    void refreshImageDestination();
  }, [loadConfig, loadEvalIso, loadLinuxNetboot, loadStoreIsos, loadTracker, refreshImageDestination]);

  const ensureBinary = useCallback(async () => {
    setInstallBusy(true);
    try {
      await sidecar.invoke("EnsureAria2Binary", await aria2SidecarParams());
      await loadConfig();
    } catch (e) {
      toast.error("aria2 install", e instanceof Error ? e.message : String(e));
    } finally {
      setInstallBusy(false);
    }
  }, [loadConfig]);

  useEffect(() => {
    if (!config?.pluginEnabled || config.binary?.ready || config.binary?.installing) return;
    void ensureBinary();
  }, [config?.pluginEnabled, config?.binary?.ready, config?.binary?.installing, ensureBinary]);

  useEffect(() => {
    if (!config?.binary?.installing) return;
    const id = window.setInterval(() => {
      void loadConfig();
    }, 1500);
    return () => window.clearInterval(id);
  }, [config?.binary?.installing, loadConfig]);

  useEffect(() => {
    // OS images and Drivers render from the same catalog payload.
    if (tab === "images" || tab === "drivers") void loadTracker();
  }, [tab, loadTracker]);

  useEffect(() => {
    const unsub = onSidecarEvent((ev) => {
      if (ev.event === "driver-download-progress") {
        const data = ev.data as
          | { key?: string; bytesDone?: number; totalBytes?: number; done?: boolean; failed?: boolean; cancelled?: boolean; queued?: boolean; message?: string; fileName?: string }
          | undefined;
        if (data?.key) {
          const key = data.key;
          if (data.done && data.cancelled) {
            // User cancel - release the row back to its plain state.
            setDriverDownloads((prev) => {
              const { [key]: _gone, ...rest } = prev;
              return rest;
            });
            const label = driverLabelsRef.current[key] ?? data.fileName ?? key;
            toast.info("Driver pack", `${label} cancelled.`);
          } else if (data.queued && !data.done) {
            setDriverDownloads((prev) => ({
              ...prev,
              [key]: { bytesDone: 0, totalBytes: 0, queued: true },
            }));
          } else if (data.done && data.failed) {
            // Terminal failure - keep the row flagged so it reads "Failed", not
            // "Download"; the user retries deliberately (no auto-retry).
            setDriverDownloads((prev) => ({
              ...prev,
              [key]: { bytesDone: 0, totalBytes: 0, failed: true, message: data.message ?? "download error" },
            }));
            const label = driverLabelsRef.current[key] ?? data.fileName ?? key;
            toast.error("Driver pack", `${label} failed - ${data.message ?? "download error"}`);
          } else {
            // Live progress, or done: the transfer finished but the pack is
            // still promoting - hold the bar at 100% until aria2-promote.
            setDriverDownloads((prev) => ({
              ...prev,
              [key]: { bytesDone: data.bytesDone ?? 0, totalBytes: data.totalBytes ?? 0 },
            }));
          }
        }
        return;
      }
      if (ev.event === "eval-iso-catalog-refresh") {
        const data = ev.data as { error?: string; entries?: number; automatic?: boolean } | undefined;
        setEvalIsoBusy(false);
        void loadEvalIso();
        if (data?.error) {
          toast.error("Windows media", data.error);
        } else if (!data?.automatic) {
          toast.success("Windows media", `Catalog updated (${data?.entries ?? 0} download(s) offered).`);
        }
        return;
      }
      if (ev.event === "vendor-catalog-refresh") {
        void finishVendorCatalogRefresh(
          ev.data as VendorSccmCatalogRefreshResponse & { error?: string },
        );
        return;
      }
      if (ev.event === "aria2-tools") {
        const data = ev.data as { phase?: string; message?: string } | undefined;
        if (data?.phase === "failed") {
          toast.error("aria2 install failed", data.message ?? "Download failed");
        }
        void loadConfig();
        return;
      }
      if (ev.event === "aria2-promote") {
        const data = ev.data as
          | { ok?: boolean; assetKind?: string; message?: string; direct?: boolean; key?: string; fileName?: string }
          | undefined;
        if (data?.direct && data.key) {
          // Direct driver pack landed (or promote failed) - release its row.
          const key = data.key;
          setDriverDownloads((prev) => {
            const { [key]: _gone, ...rest } = prev;
            return rest;
          });
        }
        if (data?.ok) {
          if (data.direct) {
            const label = (data.key && driverLabelsRef.current[data.key]) ?? data.fileName ?? "Pack";
            toast.success("Driver pack", `${label} installed into Netboot.`);
          } else {
            toast.success("aria2", `Promoted ${data.assetKind ?? "download"} into Netboot store.`);
          }
          void refreshDownloads();
          void loadTracker();
          void loadEvalIso();
          void loadStoreIsos();
          void refreshImageDestination();
        } else if (data?.message) {
          toast.error("aria2 promote", data.message);
        }
      }
    });
    return () => {
      void unsub.then((fn) => fn());
    };
  }, [loadConfig, loadEvalIso, loadStoreIsos, loadTracker, refreshDownloads, refreshImageDestination, finishVendorCatalogRefresh]);

  useEffect(() => {
    if (!config?.daemonRunning) {
      if (pollRef.current) {
        window.clearInterval(pollRef.current);
        pollRef.current = null;
      }
      return;
    }
    void refreshDownloads();
    pollRef.current = window.setInterval(() => {
      void refreshDownloads();
    }, POLL_MS);
    return () => {
      if (pollRef.current) {
        window.clearInterval(pollRef.current);
        pollRef.current = null;
      }
    };
  }, [config?.daemonRunning, refreshDownloads]);

  const startDaemon = useCallback(async () => {
    setDaemonBusy(true);
    try {
      if (!config?.binary?.ready) {
        await sidecar.invoke("EnsureAria2Binary", await aria2SidecarParams());
        await loadConfig();
      }
      await sidecar.invoke("StartAria2Daemon", await aria2SidecarParams());
      toast.success("aria2", "Daemon started.");
      await loadConfig();
      await refreshDownloads();
    } catch (e) {
      toast.error("aria2 start", e instanceof Error ? e.message : String(e));
    } finally {
      setDaemonBusy(false);
    }
  }, [config?.binary?.ready, loadConfig, refreshDownloads]);

  const stopDaemon = useCallback(async () => {
    setDaemonBusy(true);
    try {
      await sidecar.invoke("StopAria2Daemon");
      setDownloads(null);
      toast.success("aria2", "Daemon stopped.");
      await loadConfig();
    } catch (e) {
      toast.error("aria2 stop", e instanceof Error ? e.message : String(e));
    } finally {
      setDaemonBusy(false);
    }
  }, [loadConfig]);

  const saveSettings = useCallback(async () => {
    setLoadingConfig(true);
    try {
      const data = await sidecar.invoke<Aria2PluginConfig>(
        "SetAria2PluginConfig",
        await aria2SidecarParams({ extensionRoutes }),
      );
      setConfig(data);
      toast.success("aria2", "Settings saved.");
    } catch (e) {
      toast.error("aria2 save", e instanceof Error ? e.message : String(e));
    } finally {
      setLoadingConfig(false);
    }
  }, [extensionRoutes]);

  const queueDownload = useCallback(
    async (
      params: {
        kind?: "uri" | "torrent";
        torrentId?: string;
        uris?: string[];
        torrentBase64?: string;
        assetKind?: AssetKind;
        modelAlias?: string;
        vendor?: string;
        folder?: string;
        fileNameHint?: string;
        expectedHash?: string;
        expectedHashAlgorithm?: string;
        catalogRowId?: string;
      },
      progress?: { driverKey: string; label: string },
    ) => {
      const directDriver = isDirectDriverHttpDownload(params);

      // Pre-flight: warn (non-blocking) when the destination volume is low on
      // space before queuing a potentially large image/driver download.
      const LOW_SPACE_BYTES = 5 * 1024 * 1024 * 1024;
      const info = await getImageLibraryFreeSpace();
      if (info?.ok) {
        setImageFreeBytes(info.freeBytes);
        if (info.freeBytes != null && info.freeBytes < LOW_SPACE_BYTES) {
          toast.warn(
            "Low disk space",
            `Only ${formatBytes(info.freeBytes)} free at the ISO & driver root - large downloads may fail. Change it in Settings -> Downloads.`,
          );
        }
      }

      if (directDriver && progress) {
        // Optimistic connecting spinner; the event stream takes over from here
        // (progress -> bar, promote -> success toast + release, failure -> error).
        driverLabelsRef.current[progress.driverKey] = progress.label;
        setDriverDownloads((prev) => ({ ...prev, [progress.driverKey]: { bytesDone: 0, totalBytes: 0 } }));
      } else {
        setAdding(true);
      }

      try {
        const result = await sidecar.invoke<{
          direct?: boolean;
          accepted?: boolean;
          alreadyRunning?: boolean;
          key?: string;
          fileName?: string;
        }>(
          "AddAria2Download",
          await aria2SidecarParams({
            ...params,
            ...(directDriver && progress ? { progressKey: progress.driverKey } : {}),
          }),
        );
        if (result?.direct) {
          if (result.alreadyRunning) {
            toast.info("Driver pack", `${progress?.label ?? result.fileName ?? "Pack"} is already downloading.`);
          } else if (!progress) {
            // Manual Add-tab driver URL - no row to watch, so say it started.
            if (result.key && result.fileName) driverLabelsRef.current[result.key] = result.fileName;
            toast.info("Driver pack", `${result.fileName ?? "Download"} started.`);
          }
        } else {
          toast.success("aria2", "Download queued - progress shows under OS images.");
          await refreshDownloads();
          setTab("images");
        }
      } catch (e) {
        if (directDriver && progress) {
          const key = progress.driverKey;
          setDriverDownloads((prev) => {
            const { [key]: _gone, ...rest } = prev;
            return rest;
          });
        }
        toast.error("aria2 add", e instanceof Error ? e.message : String(e));
      } finally {
        setAdding(false);
      }
    },
    [refreshDownloads],
  );

  const addUri = useCallback(async () => {
    const raw = uriInput.trim();
    if (!raw) {
      toast.error("aria2", "Enter a magnet link, torrent URL, or HTTP(S) URL.");
      return;
    }
    if (assetKind === "driver" && !modelAlias.trim()) {
      toast.error("aria2", "Driver downloads need a model alias (e.g. P414-53) or pick from Tracker.");
      return;
    }
    await queueDownload({
      kind: "uri",
      uris: [raw],
      assetKind,
      modelAlias: modelAlias.trim() || undefined,
    });
    setUriInput("");
  }, [assetKind, modelAlias, queueDownload, uriInput]);

  const addTorrentFile = useCallback(async () => {
    try {
      const picked = await open({
        multiple: false,
        directory: false,
        filters: [{ name: "Torrent", extensions: ["torrent"] }],
      });
      if (!picked || Array.isArray(picked)) return;
      const bytes = await readFile(picked);
      const b64 = bytesToBase64(bytes);
      if (assetKind === "driver" && !modelAlias.trim()) {
        toast.error("aria2", "Driver torrents need a model alias or pick from Tracker.");
        return;
      }
      await queueDownload({
        kind: "torrent",
        torrentBase64: b64,
        assetKind,
        modelAlias: modelAlias.trim() || undefined,
        fileNameHint: typeof picked === "string" ? basename(picked) : undefined,
      });
    } catch (e) {
      toast.error("aria2 torrent", e instanceof Error ? e.message : String(e));
    }
  }, [assetKind, modelAlias, queueDownload]);

  const downloadOemRow = useCallback(
    async (row: Aria2TrackerOemIsoRow) => {
      if (row.uri) {
        await queueDownload({
          kind: "uri",
          uris: [row.uri],
          assetKind: "iso",
          catalogRowId: row.id,
        });
        return;
      }
      await queueDownload({ torrentId: row.id, assetKind: "iso" });
    },
    [queueDownload],
  );


  const downloadTrackerRow = useCallback(
    async (row: Aria2TrackerDriverRow) => {
      const uri = isHttpUrl(row.uri) ? row.uri! : (row.magnet ?? row.uri);
      if (!uri) {
        toast.warn("aria2", "No torrent/HTTP source in tracker manifest for this model yet.");
        return;
      }
      await queueDownload(
        {
          kind: "uri",
          uris: [uri],
          assetKind: "driver",
          vendor: row.vendor,
          folder: row.folder,
          modelAlias: row.aliases?.[0] ?? row.folder,
          fileNameHint: row.expectedArchive ?? undefined,
          expectedHash: row.expectedHash ?? undefined,
          expectedHashAlgorithm: row.expectedHashAlgorithm ?? undefined,
        },
        { driverKey: driverTrackerRowKey(row), label: driverTrackerRowLabel(row) },
      );
    },
    [queueDownload],
  );

  const controlDownload = useCallback(
    async (gid: string, action: "pause" | "unpause" | "remove" | "forceRemove") => {
      try {
        await sidecar.invoke("ControlAria2Download", { gid, action });
        await refreshDownloads();
      } catch (e) {
        toast.error("aria2", e instanceof Error ? e.message : String(e));
      }
    },
    [refreshDownloads],
  );

  const openDownloadFolder = useCallback(async () => {
    try {
      await sidecar.invoke("OpenAria2DownloadFolder", await aria2SidecarParams());
    } catch (e) {
      toast.error("aria2", e instanceof Error ? e.message : String(e));
    }
  }, []);

  const transferColumns: DataTableColumn<Aria2DownloadRow>[] = useMemo(
    () => [
      {
        key: "name",
        label: "Name",
        sortValue: (r) => basename(r.name),
        render: (r) => (
          <span className="truncate max-w-[14rem] inline-block" title={r.name ?? undefined}>
            {basename(r.name)}
          </span>
        ),
      },
      {
        key: "kind",
        label: "Kind",
        width: 70,
        sortValue: (r) => r.assetKind ?? "",
        render: (r) => r.assetKind ?? "-",
      },
      {
        key: "promote",
        label: "Promote",
        width: 90,
        sortValue: (r) => r.promoteStatus ?? "",
        render: (r) => {
          if (!r.promoteStatus) return "-";
          if (r.promoteStatus === "promoted") return "OK Netboot";
          if (r.promoteStatus === "failed") return r.promoteError ?? "failed";
          return r.promoteStatus;
        },
      },
      {
        key: "status",
        label: "Status",
        width: 80,
        sortValue: (r) => r.status,
        render: (r) => r.status,
      },
      {
        key: "progress",
        label: "Progress",
        sortValue: (r) => r.percent,
        render: (r) =>
          `${r.percent}% (${formatBytes(r.completedLength)} / ${formatBytes(r.totalLength)})`,
      },
      {
        key: "speed",
        label: "Speed",
        width: 80,
        sortValue: (r) => r.downloadSpeed,
        render: (r) => formatSpeed(r.downloadSpeed),
      },
      {
        key: "actions",
        label: "",
        sortValue: () => "",
        render: (r) => (
          <span className="flex gap-1 flex-wrap">
            {r.status === "active" && (
              <button type="button" className="btn btn-xs" onClick={() => void controlDownload(r.gid, "pause")}>
                Pause
              </button>
            )}
            {r.status === "paused" && (
              <button type="button" className="btn btn-xs" onClick={() => void controlDownload(r.gid, "unpause")}>
                Resume
              </button>
            )}
            <button type="button" className="btn btn-xs" onClick={() => void controlDownload(r.gid, "remove")}>
              Remove
            </button>
          </span>
        ),
      },
    ],
    [controlDownload],
  );

  const oemRows = useMemo(() => {
    const rows = tracker?.oemIsos ?? [];
    const q = imagesFilter.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((r) =>
      [r.name, r.id, r.assetKind, r.subfolder ?? "", r.source ?? ""].join(" ").toLowerCase().includes(q),
    );
  }, [tracker, imagesFilter]);

  const acerRows = useMemo(() => {
    const rows = (tracker?.drivers ?? []).filter((r) => r.vendor === "Acer");
    const q = driversFilter.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((r) => {
      const hay = [
        r.folder,
        r.modelName ?? "",
        r.catalogFamily ?? "",
        r.expectedArchive ?? "",
        ...(r.aliases ?? []),
        ...(r.nsspLabels ?? []),
      ]
        .join(" ")
        .toLowerCase();
      return hay.includes(q);
    });
  }, [tracker, driversFilter]);

  const lenovoRows = useMemo(() => {
    const rows = (tracker?.drivers ?? []).filter((r) => r.vendor === "LENOVO");
    const q = driversFilter.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((r) => {
      const hay = [
        r.folder,
        r.modelName ?? "",
        r.catalogFamily ?? "",
        r.expectedArchive ?? "",
        ...(r.aliases ?? []),
        ...(r.nsspLabels ?? []),
      ]
        .join(" ")
        .toLowerCase();
      return hay.includes(q);
    });
  }, [tracker, driversFilter]);

  const dellRows = useMemo(() => {
    const rows = (tracker?.drivers ?? []).filter((r) => r.vendor === "Dell");
    const q = driversFilter.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((r) => {
      const hay = [
        r.folder,
        r.modelName ?? "",
        r.catalogFamily ?? "",
        r.expectedArchive ?? "",
        ...(r.aliases ?? []),
        ...(r.nsspLabels ?? []),
      ]
        .join(" ")
        .toLowerCase();
      return hay.includes(q);
    });
  }, [tracker, driversFilter]);

  const hpRows = useMemo(() => {
    const rows = (tracker?.drivers ?? []).filter((r) => r.vendor === "HP");
    const q = driversFilter.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((r) => {
      const hay = [
        r.folder,
        r.modelName ?? "",
        r.catalogFamily ?? "",
        r.expectedArchive ?? "",
        ...(r.aliases ?? []),
        ...(r.nsspLabels ?? []),
      ]
        .join(" ")
        .toLowerCase();
      return hay.includes(q);
    });
  }, [tracker, driversFilter]);

  const microsoftRows = useMemo(() => {
    const rows = (tracker?.drivers ?? []).filter((r) => r.vendor === "Microsoft");
    const q = driversFilter.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((r) => {
      const hay = [
        r.folder,
        r.modelName ?? "",
        r.catalogFamily ?? "",
        r.expectedArchive ?? "",
        ...(r.aliases ?? []),
        ...(r.nsspLabels ?? []),
      ]
        .join(" ")
        .toLowerCase();
      return hay.includes(q);
    });
  }, [tracker, driversFilter]);

  const acerDriverCount = tracker?.drivers?.filter((r) => r.vendor === "Acer").length ?? 0;
  const lenovoDriverCount = tracker?.drivers?.filter((r) => r.vendor === "LENOVO").length ?? 0;
  const dellDriverCount = tracker?.drivers?.filter((r) => r.vendor === "Dell").length ?? 0;
  const hpDriverCount = tracker?.drivers?.filter((r) => r.vendor === "HP").length ?? 0;
  const microsoftDriverCount = tracker?.drivers?.filter((r) => r.vendor === "Microsoft").length ?? 0;

  const tableRows = useMemo(() => {
    if (!downloads) return [];
    return [...downloads.active, ...downloads.waiting, ...downloads.stopped];
  }, [downloads]);

  // Transfers live with their content: image-kind transfers under OS images, everything
  // else (manual/other adds) under Add. Driver packs download directly and never appear.
  const imageTransfers = useMemo(
    () => tableRows.filter((r) => r.assetKind === "wim" || r.assetKind === "iso"),
    [tableRows],
  );
  const otherTransfers = useMemo(
    () => tableRows.filter((r) => !(r.assetKind === "wim" || r.assetKind === "iso")),
    [tableRows],
  );
  // With no catalog tab mounted (the Transfers node), there is nowhere else for
  // image transfers to appear - so list everything here.
  const showsCatalogs = visibleTabs.includes("images") || visibleTabs.includes("drivers");
  const listedTransfers = showsCatalogs ? otherTransfers : tableRows;
  /** Live transfer for a catalog row - matched by the catalogRowId the job store
   * records at add time. (Name equality never matched: aria2 row names are file
   * paths / torrent info names, not the manifest display string.) */
  const findImageTransfer = useCallback(
    (rowId: string) =>
      imageTransfers.find(
        (t) =>
          t.catalogRowId === rowId &&
          (t.status === "active" || t.status === "waiting" || t.status === "paused"),
      ),
    [imageTransfers],
  );


  // "checked 3h ago" / "never checked" - the catalog is a two-week cache, so say so.
  const evalIsoStatusText = useMemo(() => {
    if (!evalIso?.cached) return "never checked";
    const age = evalIso.ageHours;
    if (age == null) return "checked recently";
    const label = age < 1 ? "just now" : age < 48 ? `${Math.round(age)}h ago` : `${Math.round(age / 24)}d ago`;
    return evalIso.stale ? `checked ${label} (stale)` : `checked ${label}`;
  }, [evalIso]);

  // What "Download all" would fetch: everything offered that is not already in the store.
  const evalIsoPending = useMemo(() => {
    const rows = (evalIso?.entries ?? []).filter((r) => !r.downloaded && r.url);
    return {
      count: rows.length,
      bytes: rows.reduce((sum, r) => sum + (r.sizeBytes || 0), 0),
      names: rows.map((r) => `${r.productName}${r.edition === "LTSC" ? " LTSC" : ""}`).join(", "),
    };
  }, [evalIso]);

  const isoRows = useMemo(() => {
    const needle = imagesFilter.trim().toLowerCase();
    const rows = needle
      ? storeIsos.filter((r) => r.fileName.toLowerCase().includes(needle))
      : storeIsos;
    return [...rows].sort((a, b) => a.fileName.localeCompare(b.fileName));
  }, [storeIsos, imagesFilter]);

  const isoColumns: DataTableColumn<PxeBootIsoEntry>[] = useMemo(
    () => [
      {
        key: "fileName",
        label: "ISO",
        sortValue: (r) => r.fileName,
        render: (r) => (
          <span className="flex flex-col">
            <span>{r.label || r.fileName}</span>
            {r.label ? (
              <span className="text-[10px]" style={{ color: "var(--text3)" }}>
                {r.fileName}
              </span>
            ) : null}
            {r.bootKind === "linux" && r.bootLabel ? (
              <span className="text-[10px]" style={{ color: "var(--text3)" }} title="Mounted in place; the PXE menu boots its kernel and initrd straight off the ISO">
                PXE menu: {r.bootLabel}
              </span>
            ) : null}
            {r.bootKind === "linux" && r.bootNote ? (
              <span className="text-[10px]" style={{ color: "var(--text3)" }}>
                {r.bootNote}
              </span>
            ) : null}
          </span>
        ),
      },
      {
        key: "size",
        label: "Size",
        width: 80,
        sortValue: (r) => r.sizeBytes,
        render: (r) => formatBytes(r.sizeBytes),
      },
      {
        key: "actions",
        label: "",
        width: 80,
        sortValue: () => "",
        render: (r) => (
          <button type="button" className="table-action" disabled={isoBusy} onClick={() => void removeIso(r)}>
            Remove
          </button>
        ),
      },
    ],
    [isoBusy, removeIso],
  );

  // Debian network installers: one row per release x arch the app offers. Ready rows are
  // on the PXE menu (with the task-sequence submenu); Add fetches the pair, Remove drops it.
  const linuxNetbootColumns: DataTableColumn<PxeBootLinuxNetbootEntry>[] = useMemo(
    () => [
      {
        key: "release",
        label: "Linux installer",
        sortValue: (r) => `${r.label} ${r.arch}`,
        render: (r) => (
          <span className="flex flex-col">
            <span>
              {r.label} {r.arch}
            </span>
            <span className="text-[10px]" style={{ color: "var(--text3)" }}>
              {r.ready
                ? `on the PXE menu - netboot d-i ${r.diVersion || "current"}, ${formatBytes(r.sizeBytes)} in the store`
                : "not fetched - Add downloads the kernel and initrd from the mirror"}
            </span>
          </span>
        ),
      },
      {
        key: "state",
        label: "State",
        width: 90,
        sortValue: (r) => (r.ready ? 1 : 0),
        render: (r) => (r.ready ? "Ready" : "-"),
      },
      {
        key: "actions",
        label: "",
        width: 80,
        sortValue: () => "",
        render: (r) => (
          <button
            type="button"
            className="table-action"
            disabled={linuxNetbootBusy !== null}
            title={r.ready ? "Remove the netboot files and the menu entry" : "Fetch the current netboot kernel and initrd (about 95 MB) and add the menu entry"}
            onClick={() => void (r.ready ? removeLinuxNetboot(r) : addLinuxNetboot(r))}
          >
            {linuxNetbootBusy === r.id ? "Working..." : r.ready ? "Remove" : "Add"}
          </button>
        ),
      },
    ],
    [addLinuxNetboot, linuxNetbootBusy, removeLinuxNetboot],
  );

  // Microsoft Evaluation Center rows. Progress rides the same driver-download-progress
  // channel as driver packs (key "eval|<id>"), so the bar here is the shared one.
  const evalIsoColumns: DataTableColumn<EvalIsoEntry>[] = useMemo(
    () => [
      {
        key: "name",
        label: "Windows media",
        sortValue: (r) => `${r.productName} ${r.edition}`,
        render: (r) => (
          <span className="flex flex-col">
            <span>
              {r.productName}
              {r.edition === "LTSC" ? " LTSC" : ""}
            </span>
            <span className="text-[10px]" style={{ color: "var(--text3)" }}>
              {[r.release, r.build, r.arch !== "x64" ? r.arch : null, r.culture].filter(Boolean).join(" | ")}
            </span>
          </span>
        ),
      },
      {
        key: "size",
        label: "Size",
        width: 80,
        sortValue: (r) => r.sizeBytes,
        render: (r) => formatBytes(r.sizeBytes),
      },
      {
        key: "actions",
        label: "",
        width: 120,
        sortValue: () => "",
        render: (r) => {
          const key = `eval|${r.id}`;
          const live = driverDownloads[key];
          if (live && !live.failed) {
            const pct = live.totalBytes > 0 ? Math.min(100, Math.floor((live.bytesDone / live.totalBytes) * 100)) : 0;
            return (
              <span
                className="inline-flex items-center gap-1.5"
                title={`${formatBytes(live.bytesDone)} of ${formatBytes(live.totalBytes)}`}
              >
                <span
                  aria-hidden
                  style={{ width: 44, height: 4, borderRadius: 2, background: "var(--surface3)", overflow: "hidden", display: "inline-block" }}
                >
                  <span style={{ display: "block", width: `${pct}%`, height: "100%", background: "var(--accent)", transition: "width 0.3s linear" }} />
                </span>
                {live.totalBytes > 0 ? `${pct}%` : "..."}
              </span>
            );
          }
          if (r.downloaded) {
            return (
              <span className="text-[11px]" style={{ color: "var(--text3)" }} title={r.fileName}>
                Downloaded
              </span>
            );
          }
          return (
            <button
              type="button"
              className="table-action"
              disabled={!r.url}
              title={r.fileName ? `${r.fileName}${live?.failed ? ` - last attempt failed: ${live.message ?? ""}` : ""}` : r.url}
              onClick={() => void downloadEvalIso(r)}
            >
              {live?.failed ? "Retry" : "Download"}
            </button>
          );
        },
      },
    ],
    [downloadEvalIso, driverDownloads],
  );

  const oemColumns: DataTableColumn<Aria2TrackerOemIsoRow>[] = useMemo(
    () => [
      {
        key: "name",
        label: "Image",
        sortValue: (r) => r.name,
        render: (r) => r.name,
      },
      {
        key: "kind",
        label: "Kind",
        width: 60,
        sortValue: (r) => r.assetKind,
        render: (r) => r.assetKind,
      },
      {
        key: "size",
        label: "Size",
        width: 90,
        sortValue: (r) => r.sizeBytes,
        render: (r) => formatBytes(r.sizeBytes),
      },
      {
        key: "seeders",
        label: "S",
        width: 44,
        sortValue: (r) => r.seeders ?? -1,
        render: (r) => formatPeerCount(r.seeders),
      },
      {
        key: "leechers",
        label: "L",
        width: 44,
        sortValue: (r) => r.leechers ?? -1,
        render: (r) => formatPeerCount(r.leechers),
      },
      {
        key: "actions",
        label: "",
        sortValue: () => "",
        render: (r) => {
          const live = findImageTransfer(r.id);
          if (live) {
            const pct = Math.min(100, Math.floor(live.percent));
            return (
              <span
                className="inline-flex items-center gap-1.5"
                title={`${formatBytes(live.completedLength)} of ${formatBytes(live.totalLength)} | ${formatSpeed(live.downloadSpeed)}`}
              >
                <span
                  aria-hidden
                  style={{ width: 44, height: 4, borderRadius: 2, background: "var(--surface3)", overflow: "hidden", display: "inline-block" }}
                >
                  <span
                    style={{ display: "block", width: `${pct}%`, height: "100%", background: "var(--accent)", transition: "width 0.3s linear" }}
                  />
                </span>
                {pct}%
              </span>
            );
          }
          return (
            <button
              type="button"
              className="table-action"
              disabled={!config?.daemonRunning || adding || !r.downloadable}
              onClick={() => void downloadOemRow(r)}
            >
              Download
            </button>
          );
        },
      },
    ],
    [adding, config?.daemonRunning, downloadOemRow, findImageTransfer],
  );

  const vendorDriverColumns: DataTableColumn<Aria2TrackerDriverRow>[] = useMemo(
    () => [
      {
        key: "model",
        label: "Model",
        sortValue: (r) => r.modelName ?? r.folder,
        render: (r) => (
          <span title={[r.modelName, r.nsspLabels?.join(", ")].filter(Boolean).join(" | ") || undefined}>
            {r.modelName ? (
              <>
                {r.modelName}
                <span style={{ color: "var(--text2)" }}> ({r.folder})</span>
              </>
            ) : (
              r.folder
            )}
          </span>
        ),
      },
      {
        key: "aliases",
        label: "Aliases",
        sortValue: (r) => (r.aliases ?? []).join(","),
        render: (r) => (r.aliases?.length ? r.aliases.join(", ") : "-"),
      },
      {
        key: "ready",
        label: "Downloaded",
        width: 92,
        sortValue: (r) => (driverDownloads[driverTrackerRowKey(r)] ? 2 : r.archiveReady ? 1 : 0),
        render: (r) => {
          const rowKey = driverTrackerRowKey(r);
          const p = driverDownloads[rowKey];
          if (p) {
            if (p.failed) {
              return (
                <span style={{ color: "var(--red, #c33)" }} title={p.message ?? "Download failed - the bad file was removed"}>
                  x failed
                </span>
              );
            }
            if (p.queued) {
              return (
                <span style={{ color: "var(--text3)" }} title="Waiting for a download slot (10 run at once)">
                  queued
                </span>
              );
            }
            if (p.totalBytes > 0) {
              const pct = Math.min(100, Math.floor((p.bytesDone / p.totalBytes) * 100));
              return (
                <span
                  className="inline-flex items-center gap-1.5"
                  title={`${formatBytes(p.bytesDone)} of ${formatBytes(p.totalBytes)}`}
                >
                  <span
                    aria-hidden
                    style={{ width: 44, height: 4, borderRadius: 2, background: "var(--surface3)", overflow: "hidden", display: "inline-block" }}
                  >
                    <span
                      style={{ display: "block", width: `${pct}%`, height: "100%", background: "var(--accent)", transition: "width 0.3s linear" }}
                    />
                  </span>
                  {pct}%
                </span>
              );
            }
            if (p.bytesDone > 0) {
              return <span title="Size unknown - bytes received">{formatBytes(p.bytesDone)}</span>;
            }
            return (
              <span className="inline-flex items-center gap-1" title="Connecting...">
                <span className="animate-spin inline-block" aria-hidden>
                  +
                </span>
              </span>
            );
          }
          return r.archiveReady ? (
            <span style={{ color: "var(--green)" }} title={`Pack is in the driver store (Drivers/${r.vendor}/${r.folder}/)`}>
              OK
            </span>
          ) : (
            "-"
          );
        },
      },
      {
        key: "actions",
        label: "",
        sortValue: () => "",
        render: (r) => {
          const rowKey = driverTrackerRowKey(r);
          const entry = driverDownloads[rowKey];
          const isActive = Boolean(entry) && !entry?.failed;
          if (isActive) {
            return (
              <button
                type="button"
                className="table-action"
                title={entry?.queued ? "Remove from the download queue" : "Stop this download (partial file is removed)"}
                onClick={() => {
                  void sidecar
                    .invoke("CancelAria2DirectDownload", { key: rowKey })
                    .catch((e) => toast.error("Driver pack", e instanceof Error ? e.message : String(e)));
                }}
              >
                Cancel
              </button>
            );
          }
          return (
            <button
              type="button"
              className="table-action"
              disabled={
                adding ||
                !r.downloadable ||
                (driverDownloadNeedsAria2(r) && !config?.daemonRunning)
              }
              onClick={() => void downloadTrackerRow(r)}
              title={
                entry?.failed
                  ? (entry.message ?? "Download failed - retry when ready")
                  : r.archiveReady
                    ? "Replace the stored pack with a fresh copy"
                    : undefined
              }
            >
              {entry?.failed ? "Retry" : r.archiveReady ? "Re-download" : "Get pack"}
            </button>
          );
        },
      },
    ],
    [adding, config?.daemonRunning, downloadTrackerRow, driverDownloads],
  );

  const acerDriverColumns: DataTableColumn<Aria2TrackerDriverRow>[] = useMemo(
    () => [
      {
        key: "family",
        label: "Line",
        width: 72,
        sortValue: (r) => r.catalogFamily ?? "",
        render: (r) => acerCatalogFamilyLabel(r.catalogFamily),
      },
      ...vendorDriverColumns,
    ],
    [vendorDriverColumns],
  );

  const dellDriverColumns: DataTableColumn<Aria2TrackerDriverRow>[] = useMemo(
    () => [
      {
        key: "family",
        label: "Line",
        width: 88,
        sortValue: (r) => r.catalogFamily ?? "",
        render: (r) => dellCatalogFamilyLabel(r.catalogFamily),
      },
      ...vendorDriverColumns,
    ],
    [vendorDriverColumns],
  );

  const hpDriverColumns: DataTableColumn<Aria2TrackerDriverRow>[] = useMemo(
    () => [
      {
        key: "family",
        label: "Line",
        width: 88,
        sortValue: (r) => r.catalogFamily ?? "",
        render: (r) => hpCatalogFamilyLabel(r.catalogFamily),
      },
      ...vendorDriverColumns,
    ],
    [vendorDriverColumns],
  );

  const microsoftDriverColumns: DataTableColumn<Aria2TrackerDriverRow>[] = useMemo(
    () => [
      {
        key: "family",
        label: "Line",
        width: 88,
        sortValue: (r) => r.catalogFamily ?? "",
        render: (r) => microsoftCatalogFamilyLabel(r.catalogFamily),
      },
      ...vendorDriverColumns,
    ],
    [vendorDriverColumns],
  );

  const updateRoute = (index: number, patch: Partial<Aria2ExtensionRoute>) => {
    setExtensionRoutes((prev) => prev.map((r, i) => (i === index ? { ...r, ...patch } : r)));
  };

  // Verbs go to the console shell, not to a panel header. Daemon lifecycle and
  // the download folder belong to Transfers - the catalog panels only queue
  // work; the vendor catalog refresh belongs to Out-of-Box Drivers.
  const showsDrivers = visibleTabs.includes("drivers");
  const daemonRunning = Boolean(config?.daemonRunning);
  const binaryReady = Boolean(config?.binary?.ready);
  const binaryInstalling = Boolean(config?.binary?.installing);
  const consoleActions = useMemo<ConsoleNodeActions>(() => {
    const items: MenuItem[] = [];
    if (!showsCatalogs) {
      if (daemonRunning) {
        items.push({ label: "Stop Daemon", disabled: daemonBusy, onSelect: () => void stopDaemon() });
      } else if (binaryReady) {
        items.push({ label: "Start Daemon", disabled: daemonBusy, onSelect: () => void startDaemon() });
      } else {
        items.push({
          label: installBusy || binaryInstalling ? "Installing aria2..." : "Install aria2",
          disabled: installBusy || binaryInstalling,
          onSelect: () => void ensureBinary(),
        });
      }
      items.push(SEP, { label: "Open Download Folder", onSelect: () => void openDownloadFolder() });
    }
    if (showsDrivers) {
      items.push({
        label: catalogRefreshBusy ? "Refreshing Catalogs..." : "Refresh Catalogs",
        disabled: catalogRefreshBusy,
        onSelect: () => void refreshVendorCatalogs(),
      });
    }
    return { items, refresh: () => void loadConfig() };
  }, [
    showsCatalogs,
    showsDrivers,
    daemonRunning,
    binaryReady,
    binaryInstalling,
    daemonBusy,
    installBusy,
    catalogRefreshBusy,
    stopDaemon,
    startDaemon,
    ensureBinary,
    openDownloadFolder,
    refreshVendorCatalogs,
    loadConfig,
  ]);
  useConsoleActions(consoleActions);

  return (
    <PanelShell
      title={title ?? "Transfers"}
    >
      <div className="flex flex-col gap-0 text-[12px] min-h-0 flex-1" style={{ color: "var(--text)" }}>
        {visibleTabs.length > 1 && (
        <div className="flex gap-1 border-b px-4 shrink-0" style={{ borderColor: "var(--border)" }}>
          {visibleTabs.map((id) => (
            <button key={id} type="button" style={tabBtn(tab === id)} onClick={() => setTab(id)}>
              {id === "images"
                ? "OS images"
                : id === "drivers"
                  ? "Drivers"
                  : id === "add"
                    ? showsCatalogs
                      ? "Add"
                      : "Transfers"
                    : "Settings"}
            </button>
          ))}
        </div>
        )}

        <div className="flex flex-col gap-4 p-4 flex-1 min-h-0 overflow-auto">
          {tab === "add" && (
            <section className="flex flex-col gap-3 max-w-[40rem]">
              <div className="flex flex-wrap gap-2 items-center">
                <label className="text-[10px] uppercase cond" style={{ color: "var(--text3)" }}>
                  Kind
                </label>
                <select
                  className="input-box text-[11px]"
                  value={assetKind}
                  disabled={!config?.daemonRunning || adding}
                  onChange={(e) => setAssetKind(e.target.value as AssetKind)}
                >
                  <option value="auto">Auto (from URL / extension)</option>
                  <option value="iso">ISO -&gt; http/iso</option>
                  <option value="wim">WIM -&gt; http/wim</option>
                  <option value="driver">Driver pack -&gt; Drivers store</option>
                  <option value="other">Other (Settings download folder)</option>
                </select>
              </div>
              {(assetKind === "driver" || assetKind === "auto") && (
                <div className="flex flex-wrap gap-2 items-center">
                  <label className="text-[10px] uppercase cond w-full" style={{ color: "var(--text3)" }}>
                    Model alias (drivers - e.g. P414-53)
                  </label>
                  <div className="input-box flex-1 min-w-[12rem]">
                    <input
                      className="text-[11px] w-full"
                      value={modelAlias}
                      onChange={(e) => setModelAlias(e.target.value)}
                      placeholder="WMI alias or folder name"
                      disabled={!config?.daemonRunning || adding}
                    />
                  </div>
                </div>
              )}
              <div className="flex flex-wrap gap-2 items-center">
                <div className="input-box flex-1 min-w-[16rem]">
                  <input
                    className="text-[11px] w-full"
                    value={uriInput}
                    onChange={(e) => setUriInput(e.target.value)}
                    placeholder="magnet:?... or https://..."
                    disabled={!config?.daemonRunning || adding}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") void addUri();
                    }}
                  />
                </div>
                <button
                  type="button"
                  className="btn btn-primary"
                  disabled={!config?.daemonRunning || adding}
                  onClick={() => void addUri()}
                >
                  Add URL
                </button>
                <button
                  type="button"
                  className="btn"
                  disabled={!config?.daemonRunning || adding}
                  onClick={() => void addTorrentFile()}
                >
                  Add .torrent...
                </button>
              </div>
              <div
                className="text-[10.5px] flex flex-wrap items-center gap-1"
                style={{ color: "var(--text3)" }}
                title={imageRootPreview}
              >
                <span>Downloading to -&gt;</span>
                <span className="mono" style={{ color: "var(--text2)" }}>
                  {imageRootPreview || "(resolving...)"}
                </span>
                {imageFreeBytes != null && (
                  <span
                    style={{
                      color:
                        imageFreeBytes < 5 * 1024 * 1024 * 1024
                          ? "var(--amber)"
                          : "var(--text3)",
                    }}
                  >
                    ({formatBytes(imageFreeBytes)} free)
                  </span>
                )}
              </div>
              {listedTransfers.length > 0 ? (
                <div className="mt-2">
                  {showsCatalogs && (
                    <h3 className="mono mb-2 text-[10px] font-medium uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                      Transfers ({listedTransfers.length})
                    </h3>
                  )}
                  <DataTable columns={transferColumns} rows={listedTransfers} rowKey={(r) => r.gid} />
                </div>
              ) : !showsCatalogs ? (
                <p className="mt-2 text-[11px]" style={{ color: "var(--text3)" }}>
                  No transfers running.
                </p>
              ) : null}
            </section>
          )}

          {tab === "images" && (
            <section className="flex flex-col gap-2 flex-1 min-h-0">
              <div className="flex flex-col gap-1">
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="mono text-[10px] font-medium uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                    Windows evaluation media ({evalIso?.entries?.length ?? 0})
                  </h3>
                  <span className="text-[10px]" style={{ color: "var(--text3)" }}>
                    {evalIsoStatusText}
                  </span>
                  <span className="ml-auto flex items-center gap-2">
                    {evalIsoPending.count > 0 && (
                      <button
                        type="button"
                        className="btn py-0.5 text-[10px]"
                        disabled={evalIsoBusy}
                        title={`Downloads every ISO not already in the store, one at a time: ${evalIsoPending.names}`}
                        onClick={() => void downloadAllEvalIso()}
                      >
                        Download all ({evalIsoPending.count} - {formatBytes(evalIsoPending.bytes)})
                      </button>
                    )}
                    <button
                      type="button"
                      className="btn py-0.5 text-[10px]"
                      disabled={evalIsoBusy || (evalIso?.refreshing ?? false)}
                      onClick={() => void refreshEvalIso()}
                    >
                      {evalIsoBusy || evalIso?.refreshing ? "Checking..." : "Check for updates"}
                    </button>
                  </span>
                </div>
                {(evalIso?.entries?.length ?? 0) > 0 ? (
                  <DataTable columns={evalIsoColumns} rows={evalIso?.entries ?? []} rowKey={(r) => r.id} />
                ) : (
                  <p className="text-[11px]" style={{ color: "var(--text2)" }}>
                    {evalIso?.cached
                      ? "Microsoft is not offering evaluation downloads right now."
                      : "Not checked yet - use Check for updates to list current Microsoft evaluation ISOs."}
                  </p>
                )}
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <h3 className="mono text-[10px] font-medium uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                  ISO library ({storeIsos.length})
                </h3>
                <span className="text-[10px]" style={{ color: "var(--text3)" }}>
                  served by Netboot - mounted, never extracted
                </span>
                <span className="ml-auto flex items-center gap-2">
                  <button
                    type="button"
                    className="btn py-0.5 text-[10px]"
                    disabled={isoBusy}
                    onClick={() => void importIso()}
                  >
                    Import ISO...
                  </button>
                  <button
                    type="button"
                    className="btn py-0.5 text-[10px]"
                    onClick={() => void sidecar.invoke("OpenPxeBootIsoFolder")}
                  >
                    Open folder
                  </button>
                </span>
              </div>
              <div className="input-box max-w-[20rem]">
                <input
                  className="text-[11px] w-full"
                  value={imagesFilter}
                  onChange={(e) => setImagesFilter(e.target.value)}
                  placeholder="Filter image name..."
                />
              </div>
              {isoRows.length === 0 ? (
                <p className="text-[11px]" style={{ color: "var(--text2)" }}>
                  {storeIsos.length === 0
                    ? "No ISOs yet - download evaluation media above, or Import ISO... for media you already have."
                    : "No ISO matches that filter."}
                </p>
              ) : (
                <DataTable columns={isoColumns} rows={isoRows} rowKey={(r) => r.fileName} />
              )}
              <div className="mt-2">
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="mono text-[10px] font-medium uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                    Linux network installers ({(linuxNetboot?.entries ?? []).filter((r) => r.ready).length}/{linuxNetboot?.entries?.length ?? 0})
                  </h3>
                  <span className="text-[10px]" style={{ color: "var(--text3)" }}>
                    no ISO - kernel and initrd from {linuxNetboot?.mirror ?? "the Debian mirror"}; drivers and packages install straight from it, always current
                  </span>
                </div>
                {(linuxNetboot?.entries?.length ?? 0) > 0 ? (
                  <DataTable columns={linuxNetbootColumns} rows={linuxNetboot?.entries ?? []} rowKey={(r) => r.id} />
                ) : (
                  <p className="text-[11px]" style={{ color: "var(--text2)" }}>
                    Waiting for the sidecar...
                  </p>
                )}
              </div>
              {oemRows.length > 0 && (
                <div className="mt-2">
                  <h3 className="mono mb-2 text-[10px] font-medium uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                    OEM OS ({oemRows.length})
                  </h3>
                  <DataTable columns={oemColumns} rows={oemRows} rowKey={(r) => r.id} />
                </div>
              )}
              {imageTransfers.length > 0 && (
                <div className="mt-2">
                  <h3 className="mono mb-2 text-[10px] font-medium uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                    Transfers ({imageTransfers.length})
                  </h3>
                  <DataTable columns={transferColumns} rows={imageTransfers} rowKey={(r) => r.gid} />
                </div>
              )}
            </section>
          )}

          {tab === "drivers" && (
            <section className="flex flex-col gap-2 flex-1 min-h-0">
              <div className="flex gap-2 border-b flex-wrap" style={{ borderColor: "var(--border)" }}>
                <button type="button" style={tabBtn(driversView === "acer")} onClick={() => setDriversView("acer")}>
                  Acer ({acerDriverCount})
                </button>
                <button type="button" style={tabBtn(driversView === "lenovo")} onClick={() => setDriversView("lenovo")}>
                  Lenovo ({lenovoDriverCount})
                </button>
                <button type="button" style={tabBtn(driversView === "dell")} onClick={() => setDriversView("dell")}>
                  Dell ({dellDriverCount})
                </button>
                <button type="button" style={tabBtn(driversView === "hp")} onClick={() => setDriversView("hp")}>
                  HP ({hpDriverCount})
                </button>
                <button
                  type="button"
                  style={tabBtn(driversView === "microsoft")}
                  onClick={() => setDriversView("microsoft")}
                >
                  Microsoft ({microsoftDriverCount})
                </button>
              </div>
              <div className="text-[10px] opacity-70" title="Vendor catalogs are read from this workstation's cache. The sidecar checks for new catalogs every two weeks in the background; the rows you see stay until the new ones arrive. Refresh Catalogs (Action menu) checks now.">
                {catalogCheckedLabel}
              </div>
              <div className="input-box max-w-[20rem]">
                <input
                  className="text-[11px] w-full"
                  value={driversFilter}
                  onChange={(e) => setDriversFilter(e.target.value)}
                  placeholder={
                    driversView === "acer"
                      ? "Filter model, line (B1/B3/X3/P2...), alias..."
                      : driversView === "dell"
                        ? "Filter Dell model, system ID, line..."
                        : driversView === "hp"
                          ? "Filter HP model, line, SoftPaq..."
                          : driversView === "microsoft"
                            ? "Filter Surface model, SKU..."
                            : "Filter ThinkPad / Yoga model, type code..."
                  }
                />
              </div>
              {driversView === "acer" ? (
                <DataTable
                  columns={acerDriverColumns}
                  rows={acerRows}
                  rowKey={(r) => `acer|${r.folder}|${r.modelName ?? ""}`}
                />
              ) : driversView === "dell" ? (
                <DataTable
                  columns={dellDriverColumns}
                  rows={dellRows}
                  rowKey={(r) => `dell|${r.folder}|${r.modelName ?? ""}`}
                />
              ) : driversView === "microsoft" ? (
                <DataTable
                  columns={microsoftDriverColumns}
                  rows={microsoftRows}
                  rowKey={(r) => `microsoft|${r.folder}|${r.modelName ?? ""}`}
                />
              ) : driversView === "hp" ? (
                <DataTable
                  columns={hpDriverColumns}
                  rows={hpRows}
                  rowKey={(r) => `hp|${r.folder}|${r.modelName ?? ""}`}
                />
              ) : (
                <DataTable
                  columns={vendorDriverColumns}
                  rows={lenovoRows}
                  rowKey={(r) => `lenovo|${r.folder}|${r.modelName ?? ""}`}
                />
              )}
            </section>
          )}

          {tab === "settings" && (
            <section className="flex flex-col gap-4 max-w-[48rem]">
              <div>
                <h3 className="cond text-[10px] font-semibold uppercase mb-2" style={{ color: "var(--text3)" }}>
                  Extension routes
                </h3>
                <p className="mb-2 text-[11px]" style={{ color: "var(--text2)" }}>
                  First match wins - maps file extensions to asset kinds for auto-detect on Add.
                </p>
                <div className="flex flex-col gap-2">
                  {extensionRoutes.map((route, i) => (
                    <div key={`${route.ext}-${i}`} className="flex flex-wrap gap-2 items-center border p-2 rounded">
                      <input
                        className="input-box text-[11px] w-16"
                        value={route.ext}
                        onChange={(e) => updateRoute(i, { ext: e.target.value })}
                      />
                      <select
                        className="input-box text-[11px]"
                        value={route.assetKind}
                        onChange={(e) => updateRoute(i, { assetKind: e.target.value })}
                      >
                        <option value="iso">iso</option>
                        <option value="wim">wim</option>
                        <option value="driver">driver</option>
                        <option value="other">other</option>
                      </select>
                    </div>
                  ))}
                </div>
                <button
                  type="button"
                  className="btn mt-2"
                  onClick={() =>
                    setExtensionRoutes((prev) => [
                      ...prev,
                      { ext: ".zip", assetKind: "other", usePxeStaging: false, dir: null },
                    ])
                  }
                >
                  Add route
                </button>
              </div>

              <button type="button" className="btn btn-primary self-start" disabled={loadingConfig} onClick={() => void saveSettings()}>
                Save settings
              </button>
            </section>
          )}
        </div>
      </div>
    </PanelShell>
  );
}
