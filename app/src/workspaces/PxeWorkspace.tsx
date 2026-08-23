import { open } from "@tauri-apps/plugin-dialog";
import { Fragment, useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { createPortal } from "react-dom";

import { ConfirmModal } from "../components/ConfirmModal";
import { DataTable, type DataTableColumn } from "../components/DataTable";
import type { MaybeInfoTipRow } from "../components/InfoTip";
import { VaultEditorOverlay } from "../components/VaultEditorOverlay";
import { InfrastructureCredentialsOverlay } from "../components/InfrastructureCredentialsOverlay";
import { PanelShell } from "../components/PanelShell";
import { SEP } from "../components/ContextMenu";
import { useConsoleActions, type ConsoleNodeActions } from "../state/consoleActions";
import { SessionDot } from "../components/SessionDot";
import { sidecar } from "../lib/ipc";
import {
  applyPxeBootLibraryToCache,
  patchPxeBootPanelData,
  patchPxeBootPanelStatus,
  PXE_BOOT_CONFIG_CACHE_KEY,
  setPxeBootPanelData,
} from "../lib/pxeBootPanelCache";
import { revalidate as revalidateQueryKey } from "../lib/queryCache";
import { useCachedQuery } from "../lib/useCachedQuery";
import type {
  ImportPxeBootWimResult,
  ListPxeBootIsoWimsResult,
  PxeBootImagingClient,
  PxeBootImagingClientLogResponse,
  PxeBootImagingClientsResponse,
  PxeBootIsoWimEntry,
  PxeBootLogTailResponse,
  PxeBootNetworkAdapter,
  PxeBootPluginConfigResponse,
  PxeBootPluginStatus,
  PxeBootInstallImageEntry,
  PxeBootTaskSequence,
  PxeBootTaskSequenceStep,
  PxeBootTaskSequencesPayload,
  TaskSequenceLibraryEntry,
  TaskSequenceLibraryLists,
  VaultSecretsResponse,
  PxeBootWimEntry,
  PxeBootWimLibraryResponse,
  SessionState,
  SetPxeBootPluginConfigParams,
  StartPxeBootServicesParams,
  StopPxeBootServicesParams,
} from "../lib/types";
import { getImageLibraryRoot } from "../lib/imageLibrary";
import { toast } from "../state/toastStore";

const PLUGIN_TITLE = "Netboot";
const BOOT_FILE_NAME = "x86_64-sb/shimx64.efi";
const MENU_REBUILD_MESSAGE = "Rebuilding PXE menus...";
/** Keep overlay visible long enough to read; fast default-only regen can finish in <100ms. */
const MENU_REBUILD_MIN_MS = 1500;
const MENU_REBUILD_PAINT_MS = 80;
const TS_FIELD_LABELS: Record<string, string> = {
  computerName: "Computer name",
  network: "Networking",
  joinDomain: "Join domain",
  joinCredential: "Join credentials",
  machineOu: "Machine OU",
  productKey: "Product key",
  ipCidr: "IP address (CIDR)",
  gateway: "Gateway",
  dns1: "DNS",
};
/** Canonical editor order (Craig, 2026-08-20): networking block reads IP ->
 * Gateway -> DNS; dns2/dns3 fold into the dns1 row's add/remove list. */
const TS_FIELD_ORDER = [
  "computerName",
  "network",
  "ipCidr",
  "gateway",
  "dns1",
  "joinDomain",
  "joinCredential",
  "machineOu",
  "productKey",
];
const IPV4_RE = /^\d{1,3}(\.\d{1,3}){3}$/;
const IPV4_CIDR_RE = /^\d{1,3}(\.\d{1,3}){3}\/\d{1,2}$/;
const TS_KIND_LABELS: Record<string, string> = {
  client: "Client",
  server: "Server",
};
/** Field set for freshly added sequences (mirrors the sidecar seeds). */
const TS_DEFAULT_FIELDS: Record<string, string> = {
  computerName: "{{SERIAL}}",
  network: "dhcp",
  ipCidr: "",
  gateway: "",
  dns1: "",
  dns2: "",
  dns3: "",
  joinDomain: "",
  joinCredential: "",
  machineOu: "",
  productKey: "",
};
let tsStepKeyCounter = 0;
/** Deep-copy sequences for editing, stamping each step with a UI-only stable
 * React key (index keys made focus jump on reorder/remove). */
function tsWithStepKeys(sequences: PxeBootTaskSequence[]): PxeBootTaskSequence[] {
  return sequences.map((s) => ({
    ...s,
    fields: { ...s.fields },
    steps: (s.steps ?? []).map((st) => ({ ...st, _key: `s${tsStepKeyCounter++}` })),
  }));
}

/** Strip the UI-only step keys before diffing against / sending to the sidecar. */
function tsStripStepKeys(sequences: PxeBootTaskSequence[]): PxeBootTaskSequence[] {
  return sequences.map((s) => ({
    ...s,
    steps: (s.steps ?? []).map(({ _key: _ignored, ...rest }) => rest),
  }));
}

function delayMs(ms: number): Promise<void> {
  return new Promise((resolve) => {
    window.setTimeout(resolve, ms);
  });
}

/** Params for calls whose handlers resolve the image library (custom Downloads root). */
async function pxeSidecarParams(extra?: Record<string, unknown>) {
  const imageLibraryRoot = await getImageLibraryRoot();
  return { ...(imageLibraryRoot ? { imageLibraryRoot } : {}), ...extra };
}
/** Live status poll - skip while tab hidden or fetch in flight. */
const STATUS_POLL_MS = 8_000;

async function copyFieldValue(label: string, value: string) {
  try {
    await navigator.clipboard.writeText(value);
    toast.success(PLUGIN_TITLE, `${label} copied to clipboard.`);
  } catch {
    toast.error(PLUGIN_TITLE, "Could not copy to clipboard.");
  }
}

function formatFileSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "-";
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
  if (bytes >= 1024 ** 2) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

function formatModified(iso?: string): string {
  if (!iso) return "-";
  try {
    return new Date(iso).toLocaleString();
  } catch {
    return iso;
  }
}

/** Suggested boot-WIM name when extracting from an ISO, e.g. "Win11_23H2" + "boot.wim" -> "Win11_23H2-boot.wim". */
function formatAge(ageSeconds: number): string {
  if (ageSeconds < 60) return `${ageSeconds}s`;
  if (ageSeconds < 3600) return `${Math.floor(ageSeconds / 60)}m`;
  if (ageSeconds < 86400) return `${Math.floor(ageSeconds / 3600)}h ${Math.floor((ageSeconds % 3600) / 60)}m`;
  return `${Math.floor(ageSeconds / 86400)}d`;
}

function suggestedIsoWimName(isoPath: string, wimName: string): string {
  const isoBase = isoPath
    .replace(/^.*[/\\]/, "")
    .replace(/\.iso$/i, "")
    .replace(/[\\/:*?"<>|]/g, "_")
    .trim();
  const wimBase = wimName.replace(/^.*[/\\]/, "").replace(/\.wim$/i, "");
  return `${isoBase ? `${isoBase}-` : ""}${wimBase}.wim`;
}

function safeWimFileName(pathOrName: string): string {
  const base = pathOrName.replace(/^.*[/\\]/, "").trim();
  if (!base) {
    throw new Error("Invalid WIM file name.");
  }
  const name = /\.wim$/i.test(base) ? base : `${base}.wim`;
  if (/[\\/:*?"<>|]/.test(name)) {
    throw new Error("WIM file name contains invalid characters.");
  }
  return name;
}

/** PXE host settings edited in the panel - batched via Apply / Cancel (one menu rebuild). */
type PxeHostFormSnapshot = {
  httpPort: string;
  interfaceId: string;
  tftpMode: "router" | "standalone" | "proxy";
  tftpBootFile: string;
  smbShareEnabled: boolean;
  smbOverlayEnabled: boolean;
  overlayCreds: string;
  tftpd64Path: string;
};

function normalizeOverlayCreds(raw: string | undefined): string {
  const v = (raw ?? "").trim();
  if (!v || v === "blank") return "blank";
  if (v === "throwaway") return v;
  if (v.startsWith("vault:")) return v;
  return "blank";
}

function pxeHostFormFromConfig(resp: PxeBootPluginConfigResponse): PxeHostFormSnapshot {
  const mode = resp.config.tftpMode;
  const smbOverlayEnabled = resp.config.smbOverlayEnabled === true;
  let overlayCreds = normalizeOverlayCreds(resp.config.deployOverlayCreds);
  if (!smbOverlayEnabled && overlayCreds === "throwaway") {
    overlayCreds = "blank";
  }
  return {
    httpPort: String(resp.config.httpPort ?? 8080),
    interfaceId: resp.config.interfaceId ?? "",
    tftpMode: mode === "standalone" || mode === "proxy" || mode === "router" ? mode : "router",
    tftpBootFile: resp.config.tftpBootFile ?? resp.status?.tftpBootFile ?? BOOT_FILE_NAME,
    smbShareEnabled: resp.config.smbShareEnabled === true,
    smbOverlayEnabled,
    overlayCreds,
    tftpd64Path: resp.config.tftpd64Path ?? "",
  };
}

const PXE_HOST_FIELD_LABELS: Record<keyof PxeHostFormSnapshot, string> = {
  httpPort: "HTTP port",
  interfaceId: "Ethernet adapter",
  tftpMode: "TFTP mode",
  tftpBootFile: "Option 67",
  smbShareEnabled: "SMB share",
  smbOverlayEnabled: "Deploy source",
  overlayCreds: "Credentials",
  tftpd64Path: "Tftpd64 path",
};

function statusBadge(running: boolean, label: string) {
  return (
    <span
      className="badge"
      style={{
        color: running ? "var(--green)" : "var(--text3)",
        borderColor: running ? "var(--green-dim)" : "var(--border)",
      }}
    >
      {label}: {running ? "running" : "stopped"}
    </span>
  );
}

function serviceDotState(running: boolean): SessionState {
  return running ? "connected" : "unknown";
}

/** Which blocks this mount renders - one MDT node each. */
export type PxeSection = "host" | "pxeLog" | "imagingClients" | "bootImages" | "taskSequences";

const ALL_SECTIONS: PxeSection[] = ["host", "pxeLog", "imagingClients", "bootImages", "taskSequences"];

export function PxeWorkspace({
  sections = ALL_SECTIONS,
  title,
}: {
  sections?: readonly PxeSection[];
  title?: string;
} = {}) {
  const show = (key: PxeSection) => sections.includes(key);
  // A section that owns its whole panel doesn't need a heading (the panel title
  // says it) or a disclosure caret (there is nothing to collapse away from).
  const solo = sections.length === 1;
  const {
    data,
    loading: configLoading,
    error: configError,
    refetch: refetchConfig,
  } = useCachedQuery<PxeBootPluginConfigResponse>(
    PXE_BOOT_CONFIG_CACHE_KEY,
    () => sidecar.invoke<PxeBootPluginConfigResponse>("GetPxeBootPluginConfig"),
    // Live: services can be started/stopped outside the app.
    { ttlMs: 0, pollMs: STATUS_POLL_MS, invalidateOnRefetch: false },
  );
  const loading = configLoading && !data;
  // No "Refreshing..." line: this view polls every 8s, so the flag is true most of the
  // time and reads as permanently stuck (field, 2026-08-22) - especially on a screen with
  // nothing in it yet. The cached data stays on screen and updates silently instead.

  useEffect(() => {
    let alive = true;
    void (async () => {
      try {
        const lists = await sidecar.invoke<TaskSequenceLibraryLists>("GetTaskSequenceStepLibrary");
        if (alive) setStepLibrary(lists);
      } catch {
        /* library is a convenience - the manual Reg/Command/PowerShell buttons still work */
      }
    })();
    return () => {
      alive = false;
    };
  }, []);

  const [busy, setBusy] = useState(false);
  const [menuRebuildMessage, setMenuRebuildMessage] = useState<string | null>(null);
  const [httpPort, setHttpPort] = useState("8080");
  const [isoCatalogSource, setIsoCatalogSource] = useState<"local" | "wan">("local");
  const [interfaceId, setInterfaceId] = useState("");
  const [tftpd64Path, setTftpd64Path] = useState("");
  const [tftpMode, setTftpMode] = useState<"router" | "standalone" | "proxy">("router");
  const [smbShareEnabled, setSmbShareEnabled] = useState(false);
  const [smbOverlayEnabled, setSmbOverlayEnabled] = useState(false);
  const [overlayCreds, setOverlayCreds] = useState<string>("blank");
  const [tftpBootFile, setTftpBootFile] = useState(BOOT_FILE_NAME);
  const [removeTarget, setRemoveTarget] = useState<PxeBootWimEntry | null>(null);
  const [replaceConfirm, setReplaceConfirm] = useState<{ sourcePath: string; fileName: string } | null>(null);
  const [isoWimPick, setIsoWimPick] = useState<{
    isoPath: string;
    isoFileName: string;
    entries: PxeBootIsoWimEntry[];
    selected: string;
  } | null>(null);
  const [isoWimReplace, setIsoWimReplace] = useState<{
    isoPath: string;
    entry: PxeBootIsoWimEntry;
    targetFileName: string;
  } | null>(null);
  const [pxeHostExpanded, setPxeHostExpanded] = useState(true);
  const [logExpanded, setLogExpanded] = useState(true);
  const [logTail, setLogTail] = useState<PxeBootLogTailResponse | null>(null);
  const [logLoading, setLogLoading] = useState(false);
  const [imagingExpanded, setImagingExpanded] = useState(true);
  const [imagingClients, setImagingClients] = useState<PxeBootImagingClient[] | null>(null);
  const [imagingSelected, setImagingSelected] = useState<string | null>(null);
  const [imagingLog, setImagingLog] = useState<PxeBootImagingClientLogResponse | null>(null);
  const [imagingLoading, setImagingLoading] = useState(false);
  const [tsExpanded, setTsExpanded] = useState(true);
  const [tsPayload, setTsPayload] = useState<PxeBootTaskSequencesPayload | null>(null);
  // Static settings catalog, split client/server. Fetched once and cached against its
  // version - it only changes when the product ships new entries.
  const [stepLibrary, setStepLibrary] = useState<TaskSequenceLibraryLists | null>(null);
  // Per-sequence pick in the "add from library" row: { entryId, value }.
  const [libraryPick, setLibraryPick] = useState<Record<string, { entryId: string; value: string }>>({});
  const [libraryBusy, setLibraryBusy] = useState(false);
  // Editable working copy - Save publishes the whole set.
  const [tsEdit, setTsEdit] = useState<PxeBootTaskSequence[] | null>(null);
  // Install image sources for the per-sequence image dropdown. Seeded from the task
  // sequence payload (cached editions only - no ISO is mounted on a panel load); the
  // "Read editions" button asks the sidecar to mount and read what it has not seen.
  const [installImages, setInstallImages] = useState<PxeBootInstallImageEntry[]>([]);
  const [installImagesBusy, setInstallImagesBusy] = useState(false);
  // Domain join is an optional addition, not part of every sequence: a sequence is
  // "joining" when it has a domain set, or when the operator has just ticked the box
  // and has not typed one yet.
  const [tsJoinOptIn, setTsJoinOptIn] = useState<Set<string>>(new Set());
  // Vault secrets offered as join credentials, and the editor that manages them.
  const [vaultSecretNames, setVaultSecretNames] = useState<string[]>([]);
  const [vaultEditor, setVaultEditor] = useState<{ open: boolean; seqId?: string }>({ open: false });

  const loadVaultSecrets = useCallback(async () => {
    try {
      const data = await sidecar.invoke<VaultSecretsResponse>("ListVaultSecrets");
      setVaultSecretNames((data?.secrets ?? []).map((s) => s.name));
    } catch {
      /* vault may be unavailable - the picker just offers deploy-time fill */
    }
  }, []);

  useEffect(() => {
    void loadVaultSecrets();
  }, [loadVaultSecrets]);

  /** The library list that applies to a sequence: client sequences get the client list. */
  const libraryFor = useCallback(
    (kind: string): TaskSequenceLibraryEntry[] =>
      kind === "server" ? (stepLibrary?.server ?? []) : (stepLibrary?.client ?? []),
    [stepLibrary],
  );

  const addStepFromLibrary = useCallback(
    async (seqId: string, kind: string) => {
      const pick = libraryPick[seqId];
      if (!pick?.entryId) return;
      const entry = libraryFor(kind).find((e) => e.id === pick.entryId);
      setLibraryBusy(true);
      try {
        // The sidecar builds the step: substitution and validation stay server-side.
        const step = await sidecar.invoke<PxeBootTaskSequenceStep>("GetTaskSequenceStepFromLibrary", {
          entryId: pick.entryId,
          value: pick.value ?? "",
        });
        setTsEdit((prev) =>
          (prev ?? []).map((s) =>
            s.id === seqId
              ? { ...s, steps: [...(s.steps ?? []), { ...step, _key: `s${tsStepKeyCounter++}` }] }
              : s,
          ),
        );
        setLibraryPick((prev) => ({ ...prev, [seqId]: { entryId: "", value: "" } }));
        toast.success("Task sequences", `Added "${entry?.name ?? pick.entryId}" - remember to Save.`);
      } catch (e) {
        toast.error("Task sequences", e instanceof Error ? e.message : String(e));
      } finally {
        setLibraryBusy(false);
      }
    },
    [libraryFor, libraryPick],
  );
  const [tsSelectedId, setTsSelectedId] = useState<string | null>(null);
  const [tsSaving, setTsSaving] = useState(false);
  const [tsNewName, setTsNewName] = useState("");
  // Sequences whose local-domain machine OU is in "Custom..." free-text mode (the
  // select alone can't tell "custom equals the suggestion" from "picked the suggestion").
  // Preselected deploy-client menu item ("" = tech picks at the device).
  const [tsDefaultId, setTsDefaultId] = useState("");
  // Visible DNS rows per sequence (1-3; the values live in fields dns1..dns3).
  const [tsDnsVisible, setTsDnsVisible] = useState<Record<string, number>>({});
  const [credentialsOpen, setCredentialsOpen] = useState(false);

  const savedFormRef = useRef<PxeHostFormSnapshot | null>(null);
  const [savedFormVersion, setSavedFormVersion] = useState(0);

  const status: PxeBootPluginStatus | null = data?.status ?? null;
  const adapters: PxeBootNetworkAdapter[] = status?.adapters ?? [];
  const wims: PxeBootWimEntry[] = status?.wims ?? data?.layout.wims ?? [];

  const applyLibrary = useCallback((library: PxeBootWimLibraryResponse, options?: { retainStatus?: boolean }) => {
    applyPxeBootLibraryToCache(library, options);
  }, []);

  const syncFormFromConfig = useCallback((resp: PxeBootPluginConfigResponse) => {
    const snapshot = pxeHostFormFromConfig(resp);
    savedFormRef.current = snapshot;
    setSavedFormVersion((v) => v + 1);
    setHttpPort(snapshot.httpPort);
    setIsoCatalogSource(resp.config.isoCatalogSource === "wan" ? "wan" : "local");
    setInterfaceId(snapshot.interfaceId);
    setTftpd64Path(snapshot.tftpd64Path);
    setTftpMode(snapshot.tftpMode);
    setTftpBootFile(snapshot.tftpBootFile);
    setSmbShareEnabled(snapshot.smbShareEnabled);
    setSmbOverlayEnabled(snapshot.smbOverlayEnabled);
    setOverlayCreds(snapshot.overlayCreds);
  }, []);

  const reloadConfig = useCallback(() => {
    // Soft-invalidate: mark the cache stale (forces a real refetch past the TTL) but
    // keep the current data on screen so the whole panel doesn't blank out to
    // "Loading Netboot status..." for a few seconds during a stop/start cycle.
    revalidateQueryKey(PXE_BOOT_CONFIG_CACHE_KEY);
    refetchConfig();
  }, [refetchConfig]);

  const formInitRef = useRef(false);
  useEffect(() => {
    if (!data || formInitRef.current) return;
    formInitRef.current = true;
    syncFormFromConfig(data);
  }, [data, syncFormFromConfig]);

  useEffect(() => {
    let inFlight = false;

    const poll = () => {
      if (document.hidden || inFlight) return;
      inFlight = true;
      void sidecar
        .invoke<PxeBootPluginStatus>("GetPxeBootPluginStatus")
        .then((s) =>
          patchPxeBootPanelData((prev) => {
            if (!prev) return prev;
            return { ...prev, status: s };
          }),
        )
        .catch(() => undefined)
        .finally(() => {
          inFlight = false;
        });
    };

    const onVisibility = () => {
      if (!document.hidden) poll();
    };
    document.addEventListener("visibilitychange", onVisibility);
    const timer = window.setInterval(poll, STATUS_POLL_MS);
    poll();

    return () => {
      document.removeEventListener("visibilitychange", onVisibility);
      window.clearInterval(timer);
    };
  }, []);

  const refreshLog = useCallback(async () => {
    setLogLoading(true);
    try {
      const resp = await sidecar.invoke<PxeBootLogTailResponse>("GetPxeBootLogTail", { maxLines: 200 });
      setLogTail(resp);
    } catch {
      // Keep the previously shown lines on a transient read failure.
    } finally {
      setLogLoading(false);
    }
  }, []);

  // Live-tail the PXE/TFTP log only while the dropdown is open (cheap read, 3s cadence).
  useEffect(() => {
    if (!logExpanded) return;
    let active = true;
    const tick = () => {
      if (document.hidden) return;
      void sidecar
        .invoke<PxeBootLogTailResponse>("GetPxeBootLogTail", { maxLines: 200 })
        .then((resp) => {
          if (active) setLogTail(resp);
        })
        .catch(() => undefined);
    };
    tick();
    const timer = window.setInterval(tick, 3_000);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, [logExpanded]);

  const refreshImagingClients = useCallback(async () => {
    setImagingLoading(true);
    try {
      const resp = await sidecar.invoke<PxeBootImagingClientsResponse>("GetPxeBootImagingClients");
      setImagingClients(resp.clients ?? []);
    } catch {
      // Keep the previously shown clients on a transient read failure.
    } finally {
      setImagingLoading(false);
    }
  }, []);

  // Poll the imaging-client list only while the dropdown is open (cheap dir scan, 5s cadence).
  useEffect(() => {
    if (!imagingExpanded) return;
    let active = true;
    const tick = () => {
      if (document.hidden) return;
      void sidecar
        .invoke<PxeBootImagingClientsResponse>("GetPxeBootImagingClients")
        .then((resp) => {
          if (active) setImagingClients(resp.clients ?? []);
        })
        .catch(() => undefined);
    };
    tick();
    const timer = window.setInterval(tick, 5_000);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, [imagingExpanded]);

  // Live-tail the selected client's imaging log while visible (3s cadence, like the TFTP log).
  useEffect(() => {
    if (!imagingExpanded || !imagingSelected) return;
    let active = true;
    const tick = () => {
      if (document.hidden) return;
      void sidecar
        .invoke<PxeBootImagingClientLogResponse>("GetPxeBootImagingClientLog", {
          serial: imagingSelected,
          maxLines: 300,
        })
        .then((resp) => {
          if (active) setImagingLog(resp);
        })
        .catch(() => undefined);
    };
    tick();
    const timer = window.setInterval(tick, 3_000);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, [imagingExpanded, imagingSelected]);

  useEffect(() => {
    if (!tsExpanded) return;
    let cancelled = false;
    void (async () => {
      try {
        const data = await sidecar.invoke<PxeBootTaskSequencesPayload>(
          "GetPxeBootTaskSequences",
          await pxeSidecarParams(),
        );
        if (cancelled) return;
        setTsPayload(data);
        setTsEdit(tsWithStepKeys(data.sequences));
        setTsDefaultId(data.defaultSequenceId ?? "");
        setInstallImages(data.installImages ?? []);
      } catch (e) {
        if (!cancelled) toast.error("Task sequences", e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [tsExpanded]);

  const tsDirty = useMemo(() => {
    if (!tsPayload || !tsEdit) return false;
    if (tsDefaultId !== (tsPayload.defaultSequenceId ?? "")) return true;
    return JSON.stringify(tsPayload.sequences) !== JSON.stringify(tsStripStepKeys(tsEdit));
  }, [tsPayload, tsEdit, tsDefaultId]);

  /** First blocking problem across ENABLED sequences (disabled drafts may stay
   * incomplete). Static networking requires IP (CIDR) + gateway + first DNS. */
  /** Every field currently blocking a save, keyed "<sequenceId>:<field>" - the UI marks
   * them all in amber rather than explaining in prose (Craig, 2026-08-22: "orange around
   * the invalid field/s is all it needs"). dns1..dns3 all report as dns1: they share one
   * editor row. */
  const tsInvalid = useMemo(() => {
    const bad = new Set<string>();
    let first: string | null = null;
    for (const s of tsEdit ?? []) {
      if (!s.enabled) continue;
      const note = (field: string, message: string) => {
        bad.add(`${s.id}:${field}`);
        first ??= `${s.name}: ${message}`;
      };
      if (s.fields.network === "static") {
        if (!IPV4_CIDR_RE.test((s.fields.ipCidr ?? "").trim())) {
          note("ipCidr", "IP address must be IPv4/CIDR (e.g. 10.150.198.20/23).");
        }
        if (!IPV4_RE.test((s.fields.gateway ?? "").trim())) {
          note("gateway", "Gateway must be an IPv4 address.");
        }
        const dns = [s.fields.dns1, s.fields.dns2, s.fields.dns3].map((v) => (v ?? "").trim());
        if (!dns[0]) note("dns1", "at least one DNS server is required for Static IP.");
        for (let i = 0; i < dns.length; i++) {
          if (dns[i] && !IPV4_RE.test(dns[i])) note(`dns${i + 1}`, "DNS entries must be IPv4 addresses.");
        }
      }
      // A local account that cannot resolve a password is silently dropped from the
      // unattend (login-less machine, Craig 2026-08-23) - catch it here instead.
      const acct = s.localAccount;
      const acctMode = acct?.mode ?? (acct?.enabled ? (acct.passwordSource === "vault" ? "vault" : "manual") : "none");
      if (acct && acctMode === "vault") {
        if (!(acct.vaultSecret ?? "").trim()) {
          note("account:vaultSecret", "pick a vault credential for the local account.");
        }
      } else if (acct && acctMode === "manual") {
        if (!(acct.passwordPlain ?? "").trim() && !acct.password) {
          note("account:password", "the manual local account needs a password.");
        }
      }
    }
    return { fields: bad, first };
  }, [tsEdit]);
  // Kept as a string for the disabled button's tooltip.
  const tsValidationError = tsInvalid.first;

  /** Outline for the one field currently blocking a save. */
  const tsFieldOutline = useCallback(
    (seqId: string, key: string): CSSProperties | undefined =>
      tsInvalid.fields.has(`${seqId}:${key}`) ? { borderColor: "var(--amber)" } : undefined,
    [tsInvalid],
  );


  const saveTaskSequences = useCallback(async () => {
    if (!tsEdit) return;
    setTsSaving(true);
    try {
      const data = await sidecar.invoke<PxeBootTaskSequencesPayload>(
        "SavePxeBootTaskSequences",
        await pxeSidecarParams({ sequences: tsStripStepKeys(tsEdit), defaultSequenceId: tsDefaultId }),
      );
      setTsPayload(data);
      setTsEdit(tsWithStepKeys(data.sequences));
      setTsDefaultId(data.defaultSequenceId ?? "");
      if (data.installImages) setInstallImages(data.installImages);
      toast.success("Task sequences", `${data.publishedFiles.length} published to the deploy share.`);
    } catch (e) {
      toast.error("Task sequences", e instanceof Error ? e.message : String(e));
    } finally {
      setTsSaving(false);
    }
  }, [tsEdit, tsDefaultId]);

  const readInstallImageEditions = useCallback(async () => {
    setInstallImagesBusy(true);
    try {
      const data = await sidecar.invoke<{ images: PxeBootInstallImageEntry[]; unread: number }>(
        "ListPxeBootInstallImages",
        await pxeSidecarParams({ refresh: true }),
      );
      setInstallImages(data.images ?? []);
      const read = (data.images ?? []).filter((e) => e.imagesKnown).length;
      toast.success("Windows images", `${read} source(s) read.`);
    } catch (e) {
      toast.error("Windows images", e instanceof Error ? e.message : String(e));
    } finally {
      setInstallImagesBusy(false);
    }
  }, []);

  const clearImagingLogs = useCallback(async () => {
    try {
      await sidecar.invoke("ClearPxeBootImagingLogs");
      setImagingClients([]);
      setImagingSelected(null);
      setImagingLog(null);
      toast.success("Imaging logs cleared");
    } catch (err) {
      toast.error(`Failed to clear imaging logs: ${String(err)}`);
    }
  }, []);

  const clearPxeLog = useCallback(async () => {
    try {
      const res = await sidecar.invoke<{ cleared: boolean }>("ClearPxeBootLogTail");
      await refreshLog();
      toast.success(res?.cleared ? "PXE activity log cleared" : "PXE activity log was already empty");
    } catch (err) {
      toast.error(`Failed to clear PXE log: ${String(err)}`);
    }
  }, []);

  const syncConfigFromResponse = useCallback(
    (resp: PxeBootPluginConfigResponse) => {
      setPxeBootPanelData(resp);
      syncFormFromConfig(resp);
    },
    [syncFormFromConfig],
  );

  /** macOS: open admin password dialog immediately (sidecar returns while dialog stays open). */
  const prefetchMacAdminForPxe = useCallback(async (): Promise<boolean> => {
    if (status?.platform !== "macos" || status?.macOsAdminCredentialCached) {
      return true;
    }
    try {
      await sidecar.invoke("PrefetchMacOsAdminCredential", { purpose: "pxe" });
      return true;
    } catch (e) {
      toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
      return false;
    }
  }, [status?.macOsAdminCredentialCached, status?.platform]);

  const persistConfig = useCallback(
    async (
      overrides?: Partial<SetPxeBootPluginConfigParams>,
      opts?: { skipMenuRegen?: boolean },
    ): Promise<boolean> => {
      const portRaw = overrides?.httpPort ?? parseInt(httpPort.trim(), 10);
      const port = typeof portRaw === "number" ? portRaw : parseInt(String(portRaw), 10);
      if (!Number.isFinite(port) || port < 1 || port > 65535) {
        if (overrides?.httpPort === undefined) {
          toast.error(PLUGIN_TITLE, "HTTP port must be 1-65535.");
        }
        return false;
      }
      try {
        const params: SetPxeBootPluginConfigParams = {
          httpPort: port,
          isoCatalogSource: overrides?.isoCatalogSource ?? isoCatalogSource,
          interfaceId: overrides?.interfaceId ?? (interfaceId.trim() || undefined),
          tftpd64Path: overrides?.tftpd64Path ?? (tftpd64Path.trim() || undefined),
          tftpMode: overrides?.tftpMode ?? tftpMode,
          skipMenuRegen: opts?.skipMenuRegen ?? overrides?.skipMenuRegen,
        };
        // Only send when explicitly changed - Start PXE and other saves must not clobber Option 67.
        if (overrides?.tftpBootFile !== undefined) {
          params.tftpBootFile = overrides.tftpBootFile;
        }
        if (overrides?.smbShareEnabled !== undefined) {
          params.smbShareEnabled = overrides.smbShareEnabled;
        }
        if (overrides?.smbOverlayEnabled !== undefined) {
          params.smbOverlayEnabled = overrides.smbOverlayEnabled;
        }
        if (overrides?.deployOverlayCreds !== undefined) {
          params.deployOverlayCreds = overrides.deployOverlayCreds;
        }
        const resp = await sidecar.invoke<PxeBootPluginConfigResponse>("SetPxeBootPluginConfig", params);
        syncConfigFromResponse(resp);
        return true;
      } catch (e) {
        toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
        return false;
      }
    },
    [httpPort, interfaceId, isoCatalogSource, syncConfigFromResponse, tftpd64Path, tftpMode],
  );

  const withMenuRebuild = useCallback(async (run: () => Promise<void>) => {
    setMenuRebuildMessage(MENU_REBUILD_MESSAGE);
    setBusy(true);
    await delayMs(MENU_REBUILD_PAINT_MS);
    const started = Date.now();
    try {
      await run();
    } catch (e) {
      toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
    } finally {
      const remaining = MENU_REBUILD_MIN_MS - (Date.now() - started);
      if (remaining > 0) {
        await delayMs(remaining);
      }
      setMenuRebuildMessage(null);
      setBusy(false);
    }
  }, []);

  const applyConfigChange = useCallback(
    async (
      overrides: Partial<SetPxeBootPluginConfigParams>,
      opts?: { toast?: string; revert?: () => void; skipMenuRegen?: boolean },
    ): Promise<boolean> => {
      if (busy || loading || menuRebuildMessage) return false;
      let ok = false;
      await withMenuRebuild(async () => {
        ok = await persistConfig(overrides, { skipMenuRegen: opts?.skipMenuRegen });
        if (ok) {
          if (opts?.toast) toast.info(PLUGIN_TITLE, opts.toast);
        } else if (opts?.revert) {
          opts.revert();
        }
      });
      return ok;
    },
    [busy, loading, menuRebuildMessage, persistConfig, withMenuRebuild],
  );

  const currentHostForm = useMemo(
    (): PxeHostFormSnapshot => ({
      httpPort,
      interfaceId,
      tftpMode,
      tftpBootFile,
      smbShareEnabled,
      smbOverlayEnabled,
      overlayCreds,
      tftpd64Path,
    }),
    [httpPort, interfaceId, overlayCreds, smbOverlayEnabled, smbShareEnabled, tftpd64Path, tftpBootFile, tftpMode],
  );

  const dirtyHostFields = useMemo(() => {
    const saved = savedFormRef.current;
    if (!saved) return new Set<keyof PxeHostFormSnapshot>();
    const dirty = new Set<keyof PxeHostFormSnapshot>();
    (Object.keys(PXE_HOST_FIELD_LABELS) as (keyof PxeHostFormSnapshot)[]).forEach((key) => {
      if (currentHostForm[key] !== saved[key]) {
        dirty.add(key);
      }
    });
    return dirty;
  }, [currentHostForm, savedFormVersion]);

  const hostFormDirty = dirtyHostFields.size > 0;

  const dirtyHostSummary = useMemo(() => {
    if (!hostFormDirty) return "";
    return Array.from(dirtyHostFields)
      .map((key) => PXE_HOST_FIELD_LABELS[key])
      .join(", ");
  }, [dirtyHostFields, hostFormDirty]);

  const hostFieldDirty = useCallback((key: keyof PxeHostFormSnapshot) => dirtyHostFields.has(key), [dirtyHostFields]);

  const resetHostFormFromSaved = useCallback(() => {
    const saved = savedFormRef.current;
    if (!saved) return;
    setHttpPort(saved.httpPort);
    setInterfaceId(saved.interfaceId);
    setTftpMode(saved.tftpMode);
    setTftpBootFile(saved.tftpBootFile);
    setSmbShareEnabled(saved.smbShareEnabled);
    setSmbOverlayEnabled(saved.smbOverlayEnabled);
    setOverlayCreds(saved.overlayCreds);
    setTftpd64Path(saved.tftpd64Path);
  }, []);

  const applyHostFormChanges = useCallback(async () => {
    if (!hostFormDirty || busy || loading || menuRebuildMessage) return;
    const port = parseInt(httpPort.trim(), 10);
    if (!Number.isFinite(port) || port < 1 || port > 65535) {
      toast.error(PLUGIN_TITLE, "HTTP port must be 1-65535.");
      return;
    }
    const saved = savedFormRef.current;
    const onlyBootFile =
      saved &&
      dirtyHostFields.size === 1 &&
      dirtyHostFields.has("tftpBootFile");
    const overrides: Partial<SetPxeBootPluginConfigParams> = {
      httpPort: port,
      interfaceId: interfaceId.trim() || undefined,
      tftpMode,
      tftpBootFile,
      smbShareEnabled,
      smbOverlayEnabled,
      deployOverlayCreds: overlayCreds,
      tftpd64Path: tftpd64Path.trim() || undefined,
    };
    if (onlyBootFile) {
      setBusy(true);
      try {
        const ok = await persistConfig(overrides, { skipMenuRegen: true });
        if (ok) {
          toast.info(PLUGIN_TITLE, "Option 67 boot file applied.");
        }
      } finally {
        setBusy(false);
      }
      return;
    }
    await applyConfigChange(overrides, { toast: "PXE host settings applied." });
  }, [
    applyConfigChange,
    busy,
    dirtyHostFields,
    hostFormDirty,
    httpPort,
    interfaceId,
    loading,
    menuRebuildMessage,
    overlayCreds,
    persistConfig,
    smbOverlayEnabled,
    smbShareEnabled,
    tftpd64Path,
    tftpBootFile,
    tftpMode,
  ]);

  const cancelHostFormChanges = useCallback(() => {
    if (!hostFormDirty) return;
    resetHostFormFromSaved();
    toast.info(PLUGIN_TITLE, "Discarded unsaved PXE host changes.");
  }, [hostFormDirty, resetHostFormFromSaved]);

  const onInterfaceIdChange = useCallback((next: string) => {
    setInterfaceId(next);
  }, []);

  const onHttpPortChange = useCallback((next: string) => {
    setHttpPort(next);
  }, []);

  const onTftpModeChange = useCallback((next: "router" | "standalone" | "proxy") => {
    setTftpMode(next);
  }, []);

  const onSmbShareEnabledChange = useCallback((next: boolean) => {
    setSmbShareEnabled(next);
  }, []);

  const openFullDiskAccessForSmbd = useCallback(async () => {
    // smbd (not this app) is the process TCC blocks, so granting it Full Disk Access is
    // the only way to serve a Downloads/Desktop/Documents root. The sidecar opens the
    // FDA pane and reveals /usr/sbin/smbd in Finder (Tauri's shell `open` scope rejects
    // the x-apple.systempreferences: URL scheme, so both opens happen in the sidecar).
    try {
      await sidecar.invoke("RevealSmbdForFullDiskAccess");
    } catch (e) {
      toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
    }
  }, []);



  const onTftpd64PathChange = useCallback((next: string) => {
    setTftpd64Path(next);
  }, []);

  const executeImportWim = useCallback(
    async (sourcePath: string, targetFileName: string, replaceExisting: boolean) => {
      setBusy(true);
      try {
        toast.info(PLUGIN_TITLE, "Copying WIM into local store - large files may take several minutes.");
        const result = await sidecar.invoke<ImportPxeBootWimResult>("ImportPxeBootWim", {
          sourcePath,
          targetFileName,
          replaceExisting: replaceExisting || undefined,
        });
        applyLibrary(result.library);
        const bootNote =
          result.bootAssetsReady === false
            ? ""
            : result.bootAssetsPackaged && result.bootAssetsPackaged.length > 0
              ? " Boot files installed from app bundle."
              : result.bootAssetsExtracted && result.bootAssetsExtracted.length > 0
                ? " Boot files extracted from WIM."
                : " Ready for PXE.";
        toast.success(
          PLUGIN_TITLE,
          `${replaceExisting ? "Replaced" : "Added"} ${result.fileName} (${formatFileSize(result.sizeBytes)}).${bootNote}`,
        );
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        if (!replaceExisting && /already exists/i.test(message)) {
          setReplaceConfirm({ sourcePath, fileName: targetFileName });
          return;
        }
        toast.error(PLUGIN_TITLE, message);
      } finally {
        setBusy(false);
      }
    },
    [applyLibrary],
  );

  const importWim = useCallback(
    async (opts?: { replaceFileName?: string }) => {
      const picked = await open({
        multiple: false,
        filters: [{ name: "WIM boot image", extensions: ["wim"] }],
      });
      if (!picked || Array.isArray(picked)) return;

      let targetFileName: string;
      try {
        targetFileName = opts?.replaceFileName ?? safeWimFileName(picked);
      } catch (e) {
        toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
        return;
      }

      const exists = wims.some((w) => w.fileName === targetFileName);
      if (exists && !opts?.replaceFileName) {
        setReplaceConfirm({ sourcePath: picked, fileName: targetFileName });
        return;
      }

      await executeImportWim(picked, targetFileName, !!opts?.replaceFileName || exists);
    },
    [executeImportWim, wims],
  );

  const confirmReplaceWim = useCallback(async () => {
    if (!replaceConfirm) return;
    const pending = replaceConfirm;
    setReplaceConfirm(null);
    await executeImportWim(pending.sourcePath, pending.fileName, true);
  }, [executeImportWim, replaceConfirm]);

  const importWimFromIsoEntry = useCallback(
    async (isoPath: string, entry: PxeBootIsoWimEntry, replaceExisting: boolean, targetFileName?: string) => {
      const target = targetFileName ?? suggestedIsoWimName(isoPath, entry.name);
      setBusy(true);
      try {
        toast.info(PLUGIN_TITLE, `Extracting ${entry.name} from ISO - large images may take several minutes.`);
        const result = await sidecar.invoke<ImportPxeBootWimResult>("ImportPxeBootWimFromIso", {
          isoPath,
          wimPath: entry.path,
          targetFileName: target,
          replaceExisting: replaceExisting || undefined,
        });
        applyLibrary(result.library);
        const bootNote =
          result.bootAssetsReady === false
            ? ""
            : result.bootAssetsPackaged && result.bootAssetsPackaged.length > 0
              ? " Boot files installed from app bundle."
              : result.bootAssetsExtracted && result.bootAssetsExtracted.length > 0
                ? " Boot files extracted from WIM."
                : " Ready for PXE.";
        toast.success(
          PLUGIN_TITLE,
          `${replaceExisting ? "Replaced" : "Added"} ${result.fileName} (${formatFileSize(result.sizeBytes)}).${bootNote}`,
        );
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        if (!replaceExisting && /already exists/i.test(message)) {
          setIsoWimReplace({ isoPath, entry, targetFileName: target });
          return;
        }
        toast.error(PLUGIN_TITLE, message);
      } finally {
        setBusy(false);
      }
    },
    [applyLibrary],
  );

  const extractWimFromIso = useCallback(async () => {
    const picked = await open({
      multiple: false,
      filters: [{ name: "ISO image", extensions: ["iso"] }],
    });
    if (!picked || Array.isArray(picked)) return;

    let listing: ListPxeBootIsoWimsResult;
    setBusy(true);
    try {
      toast.info(PLUGIN_TITLE, "Inspecting ISO for boot images...");
      listing = await sidecar.invoke<ListPxeBootIsoWimsResult>("ListPxeBootIsoWims", { isoPath: picked });
    } catch (e) {
      toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
      return;
    } finally {
      setBusy(false);
    }

    const entries = listing.entries ?? [];
    if (entries.length === 0) {
      toast.error(PLUGIN_TITLE, "No .wim boot images found inside that ISO.");
      return;
    }
    if (entries.length === 1) {
      await importWimFromIsoEntry(picked, entries[0], false);
      return;
    }
    const preferred = entries.find((e) => e.name.toLowerCase() === "boot.wim") ?? entries[0];
    setIsoWimPick({ isoPath: picked, isoFileName: listing.isoFileName, entries, selected: preferred.path });
  }, [importWimFromIsoEntry]);

  const confirmIsoWimPick = useCallback(async () => {
    if (!isoWimPick) return;
    const pick = isoWimPick;
    const entry = pick.entries.find((e) => e.path === pick.selected) ?? pick.entries[0];
    setIsoWimPick(null);
    await importWimFromIsoEntry(pick.isoPath, entry, false);
  }, [importWimFromIsoEntry, isoWimPick]);

  const confirmIsoWimReplace = useCallback(async () => {
    if (!isoWimReplace) return;
    const pending = isoWimReplace;
    setIsoWimReplace(null);
    await importWimFromIsoEntry(pending.isoPath, pending.entry, true, pending.targetFileName);
  }, [importWimFromIsoEntry, isoWimReplace]);

  const setDefaultWim = useCallback(
    async (fileName: string) => {
      await withMenuRebuild(async () => {
        const library = await sidecar.invoke<PxeBootWimLibraryResponse>("SetPxeBootDefaultWim", { fileName });
        applyLibrary(library, { retainStatus: true });
        toast.info(
          PLUGIN_TITLE,
          `Default boot WIM: ${fileName}. PXE will auto-boot this WIM; use Refresh menu on the client after changing default.`,
        );
      });
    },
    [applyLibrary, withMenuRebuild],
  );

  const clearDefaultWim = useCallback(async () => {
    await withMenuRebuild(async () => {
      const library = await sidecar.invoke<PxeBootWimLibraryResponse>("SetPxeBootDefaultWim", { clear: true });
      applyLibrary(library, { retainStatus: true });
      toast.info(PLUGIN_TITLE, "No default WIM - clients pick from the PXE menu. Menu updates immediately.");
    });
  }, [applyLibrary, withMenuRebuild]);

  const confirmRemoveWim = useCallback(async () => {
    if (!removeTarget) return;
    setBusy(true);
    try {
      const library = await sidecar.invoke<PxeBootWimLibraryResponse>("RemovePxeBootWim", {
        fileName: removeTarget.fileName,
      });
      applyLibrary(library, { retainStatus: true });
      toast.info(PLUGIN_TITLE, `Removed ${removeTarget.fileName}.`);
      setRemoveTarget(null);
    } catch (e) {
      toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, [applyLibrary, removeTarget]);

  const openWimFolder = useCallback(async () => {
    try {
      await sidecar.invoke("OpenPxeBootWimFolder");
    } catch (e) {
      toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
    }
  }, []);

  const startServices = useCallback(async () => {
    setBusy(true);
    try {
      if (!(await prefetchMacAdminForPxe())) return;
      if (status?.platform === "macos" && !status?.macOsAdminCredentialCached) {
        toast.info(
          PLUGIN_TITLE,
          "Enter your administrator password - boot setup continues in the background.",
        );
      }
      if (!(await persistConfig(undefined, { skipMenuRegen: true }))) return;
      const s = await sidecar.invoke<PxeBootPluginStatus>("StartPxeBootServices");
      patchPxeBootPanelStatus(s);
      // SMB comes up with imaging services (unless the root is TCC-blocked on macOS).
      if (s.httpRunning && !data?.smbShare?.tccBlocked) {
        setSmbShareEnabled(true);
      }
      try {
        const refreshed = await sidecar.invoke<PxeBootPluginConfigResponse>("GetPxeBootPluginConfig");
        syncConfigFromResponse(refreshed);
      } catch {
        // Status patch above is enough for HTTP/TFTP dots; share badge may lag one poll.
      }
      if (s.httpRunning && s.tftpRunning) {
        toast.info(PLUGIN_TITLE, "TFTP + HTTP started.");
      } else if (s.httpRunning && s.tftpLastError) {
        toast.info(PLUGIN_TITLE, "HTTP started. TFTP was not started - see TFTP section below.");
      } else if (s.httpRunning) {
        toast.info(PLUGIN_TITLE, "HTTP started.");
      } else if (s.tftpRunning) {
        toast.info(PLUGIN_TITLE, "TFTP started.");
      } else {
        toast.info(PLUGIN_TITLE, "Services started (see status).");
      }
    } catch (e) {
      toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
      await reloadConfig();
    } finally {
      setBusy(false);
    }
  }, [data?.smbShare?.tccBlocked, persistConfig, prefetchMacAdminForPxe, reloadConfig, status?.macOsAdminCredentialCached, status?.platform, syncConfigFromResponse]);

  const toggleTftp = useCallback(
    async (enabled: boolean) => {
      setBusy(true);
      try {
        if (enabled) {
          if (!(await prefetchMacAdminForPxe())) return;
          if (status?.platform === "macos" && !status?.macOsAdminCredentialCached) {
            toast.info(
              PLUGIN_TITLE,
              "Enter your administrator password - TFTP setup continues in the background.",
            );
          }
          if (!(await persistConfig(undefined, { skipMenuRegen: true }))) return;
          const params: StartPxeBootServicesParams = { tftpOnly: true };
          const s = await sidecar.invoke<PxeBootPluginStatus>("StartPxeBootServices", params);
          patchPxeBootPanelStatus(s);
          if (s.tftpRunning) {
            toast.info(
              PLUGIN_TITLE,
              s.tftpElevated
                ? "TFTP server started (port 69 - administrator approved)."
                : "TFTP server started (port 69 - snponly.efi).",
            );
          }
        } else {
          const params: StopPxeBootServicesParams = { tftpOnly: true };
          const s = await sidecar.invoke<PxeBootPluginStatus>("StopPxeBootServices", params);
          patchPxeBootPanelStatus(s);
          toast.info(PLUGIN_TITLE, "TFTP server stopped.");
        }
      } catch (e) {
        toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
        await reloadConfig();
      } finally {
        setBusy(false);
      }
    },
    [persistConfig, prefetchMacAdminForPxe, reloadConfig, status?.macOsAdminCredentialCached, status?.platform],
  );

  const clearMacAdminCache = useCallback(async () => {
    setBusy(true);
    try {
      await sidecar.invoke("ClearMacOsAdminCredentialCache");
      await reloadConfig();
      toast.info(PLUGIN_TITLE, "Cached administrator password cleared.");
    } catch (e) {
      toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, [reloadConfig]);

  const toggleHttp = useCallback(
    async (enabled: boolean) => {
      setBusy(true);
      try {
        if (enabled) {
          if (!(await persistConfig(undefined, { skipMenuRegen: true }))) return;
          const params: StartPxeBootServicesParams = { httpOnly: true };
          const s = await sidecar.invoke<PxeBootPluginStatus>("StartPxeBootServices", params);
          patchPxeBootPanelStatus(s);
          toast.info(PLUGIN_TITLE, `HTTP server started on port ${httpPort.trim()}.`);
        } else {
          const params: StopPxeBootServicesParams = { httpOnly: true };
          const s = await sidecar.invoke<PxeBootPluginStatus>("StopPxeBootServices", params);
          patchPxeBootPanelStatus(s);
          toast.info(PLUGIN_TITLE, "HTTP server stopped.");
        }
      } catch (e) {
        toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
        await reloadConfig();
      } finally {
        setBusy(false);
      }
    },
    [httpPort, reloadConfig, persistConfig],
  );

  const stopServices = useCallback(async () => {
    setBusy(true);
    try {
      const s = await sidecar.invoke<PxeBootPluginStatus>("StopPxeBootServices");
      patchPxeBootPanelStatus(s);
      toast.info(PLUGIN_TITLE, "PXE stopped.");
    } catch (e) {
      toast.error(PLUGIN_TITLE, e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, []);

  const imagingColumns = useMemo(
    (): DataTableColumn<PxeBootImagingClient>[] => [
      {
        key: "status",
        label: "Seen",
        width: 72,
        sortValue: (r) => r.ageSeconds,
        render: (r) => (
          <span
            className="flex items-center gap-1.5"
            title={r.active ? "Pushed logs within the last 3 minutes" : `Last push ${formatAge(r.ageSeconds)} ago`}
          >
            <span
              style={{
                width: 6,
                height: 6,
                borderRadius: "50%",
                flexShrink: 0,
                background:
                  r.ageSeconds <= 45 ? "var(--green)" : r.ageSeconds <= 180 ? "var(--amber)" : "var(--text3)",
                boxShadow: r.ageSeconds <= 45 ? "0 0 4px var(--green)" : undefined,
              }}
            />
            {formatAge(r.ageSeconds)}
          </span>
        ),
      },
      {
        key: "serial",
        label: "Serial",
        width: 140,
        sortValue: (r) => r.serial,
        render: (r) => r.serial,
      },
      {
        key: "ip",
        label: "IP",
        width: 110,
        sortValue: (r) => r.ip ?? "",
        render: (r) => r.ip ?? "-",
      },
      {
        key: "model",
        label: "Model",
        width: 220,
        sortValue: (r) => `${r.make} ${r.model}`,
        render: (r) => `${r.make} ${r.model}`.trim(),
      },
      {
        key: "lastLine",
        label: "Last activity",
        render: (r) => (
          <span className="block max-w-[420px] truncate" title={r.lastLine}>
            {r.lastLine}
          </span>
        ),
      },
    ],
    [],
  );

  const wimColumns = useMemo((): DataTableColumn<PxeBootWimEntry>[] => {
    const hasDefault = wims.some((w) => w.isDefault);
    return [
      {
        key: "default",
        label: "Default",
        width: 72,
        sortValue: (r) => (r.isDefault ? 0 : hasDefault ? 1 : 2),
        render: (r) => (
          <input
            type="radio"
            name="pxe-default-wim"
            checked={r.isDefault}
            disabled={busy || !!menuRebuildMessage}
            title="Default - boots this WIM via wimboot at PXE"
            onChange={() => void setDefaultWim(r.fileName)}
          />
        ),
      },
      {
        key: "fileName",
        label: "Boot WIM",
        sortValue: (r) => r.fileName,
        render: (r) => (
          <span style={r.isDefault ? { color: "var(--accent2)" } : undefined}>{r.fileName}</span>
        ),
      },
      {
        key: "size",
        label: "Size",
        width: 88,
        sortValue: (r) => r.sizeBytes,
        render: (r) => formatFileSize(r.sizeBytes),
      },
      {
        key: "modified",
        label: "Modified",
        width: 148,
        sortValue: (r) => r.modifiedAt ?? "",
        render: (r) => formatModified(r.modifiedAt),
      },
      {
        key: "actions",
        label: "",
        width: 148,
        mono: false,
        render: (r) => (
          <div className="flex gap-2">
            <button className="btn" type="button" disabled={busy} onClick={() => void importWim({ replaceFileName: r.fileName })}>
              Replace
            </button>
            <button className="btn" type="button" disabled={busy} onClick={() => setRemoveTarget(r)}>
              Remove
            </button>
          </div>
        ),
      },
    ];
  }, [busy, importWim, setDefaultWim, wims]);

  const router = status?.router;
  const lanIp = status?.lanIp;
  const bootServerIp = router?.option66 ?? (lanIp ?? "<host IP>");
  const smbShareName = data?.smbShare?.shareName ?? "Deploy$";
  // The share is genuinely live only when the toggle is on AND the backend reports an
  // active share (Get-AppPxeBootImageLibraryShareStatus). Drives the dot + badge.
  const smbActive = smbShareEnabled && !!data?.smbShare?.active;
  const smbSharePath = data?.smbShare?.path ?? "<ISO & driver root>";
  const smbShareUnc = lanIp
    ? `\\\\${lanIp}\\${smbShareName}`
    : data?.smbShare?.unc ?? `\\\\<host>\\${smbShareName}`;
  const smbShareTooltip = `${smbShareName} - hidden, read-only, shared when imaging services start.\n${smbSharePath} -> ${smbShareUnc}\nThe deploy client maps it as Z: (WIMs\\, Drivers\\<model>)${
    data?.smbShare?.authUser ? `. Auth: ${data.smbShare.authDomain ?? "WORKGROUP"}\\${data.smbShare.authUser}` : ""
  }`;
  const tftpBootFiles = status?.tftpBootFiles ?? [];
  /** Saved Option 67 path - local form state, then config/status (never router poll alone). */
  const bootFileName =
    tftpBootFile ||
    data?.config?.tftpBootFile ||
    status?.tftpBootFile ||
    BOOT_FILE_NAME;
  const hasLanIp = Boolean(lanIp);

  const onTftpBootFileChange = useCallback((next: string) => {
    setTftpBootFile(next);
  }, []);

  const dirtyFieldOutline = useCallback(
    (key: keyof PxeHostFormSnapshot): CSSProperties | undefined =>
      hostFieldDirty(key) ? { outline: "1px solid var(--amber)", outlineOffset: "1px" } : undefined,
    [hostFieldDirty],
  );

  const dirtyLabelStyle = useCallback(
    (key: keyof PxeHostFormSnapshot): CSSProperties => ({
      color: hostFieldDirty(key) ? "var(--amber)" : "var(--text3)",
    }),
    [hostFieldDirty],
  );

  const headerDetails: MaybeInfoTipRow[] = [
    { label: "Mode", value: "Field PXE from this laptop" },
    !!status?.platform && { label: "Platform", value: status.platform },
    !!status?.defaultBootWim && { label: "Default", value: status.defaultBootWim },
    { label: "PXE", value: status?.running ? "active" : "stopped" },
  ];

  // Verbs go to the console shell (Action menu, right-click, toolbar), not to a
  // panel header. Service lifecycle belongs to Netboot, which owns the services;
  // other nodes only consume what those services produce.
  const showHost = show("host");
  // Three states, not two: "No LAN IP" is only true once the sidecar has
  // answered. Before that it is waiting, or it failed - and a failed call used
  // to read as "no IP found", which sent people checking cables.
  const lanIpText = !status
    ? configError
      ? `Sidecar error - ${configError}`
      : "Waiting for sidecar..."
    : status.lanIp
      ? `LAN ${status.lanIp}`
      : "No LAN IP";
  const running = Boolean(status?.running);
  const consoleActions = useMemo<ConsoleNodeActions>(
    () => ({
      items: showHost
        ? [
            { label: "Credentials...", disabled: busy || loading, onSelect: () => setCredentialsOpen(true) },
            SEP,
            {
              label: busy ? "Working..." : "Start Services",
              disabled: busy || loading || !hasLanIp,
              onSelect: () => void startServices(),
            },
            { label: "Stop Services", disabled: busy || loading || !running, onSelect: () => void stopServices() },
          ]
        : [],
      refresh: reloadConfig,
      status: lanIpText,
    }),
    [showHost, busy, loading, hasLanIp, running, startServices, stopServices, reloadConfig, lanIpText],
  );
  useConsoleActions(consoleActions);

  return (
    <>
      <PanelShell
        title={title ?? PLUGIN_TITLE}
        subtitle={
          !status ? (
            <span style={{ color: configError ? "var(--red)" : "var(--text3)" }}>{lanIpText}</span>
          ) : status.lanIp ? (
            <span>LAN {status.lanIp}</span>
          ) : (
            <span style={{ color: "var(--amber)" }}>No LAN IP</span>
          )
        }
        details={headerDetails}
      >
        <div className="flex min-h-0 flex-1 flex-col gap-4 p-4">
          {loading && (
            <p className="text-[12px]" style={{ color: "var(--text2)" }}>
              Loading Netboot status...
            </p>
          )}

          {(data || !loading) && (
            <>
              {show("host") && (
              <section
                className="rounded-sm border p-3"
                style={{
                  borderColor: hasLanIp ? "var(--accent2)" : "var(--amber)",
                  background: "var(--surface2)",
                }}
              >
                {!solo && (
                <button
                  type="button"
                  className="flex w-full items-center gap-2 text-left"
                  aria-expanded={pxeHostExpanded}
                  onClick={() => setPxeHostExpanded((open) => !open)}
                >
                  <h3 className="mono text-[10px] font-medium uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                    PXE on this host
                  </h3>
                  {!pxeHostExpanded ? (
                    <span className="ml-auto flex shrink-0 items-center gap-3">
                      {hostFormDirty ? (
                        <span className="mono text-[10px]" style={{ color: "var(--amber)" }}>
                          unsaved changes
                        </span>
                      ) : null}
                      <SessionDot
                        label="HTTP"
                        state={serviceDotState(!!status?.httpRunning)}
                        message={status?.httpRunning ? "running" : "stopped"}
                      />
                      <SessionDot
                        label="TFTP"
                        state={serviceDotState(!!status?.tftpRunning)}
                        message={status?.tftpRunning ? "running" : "stopped"}
                      />
                      <SessionDot
                        label="SMB"
                        state={serviceDotState(smbActive)}
                        message={smbActive ? `shared (${smbShareName})` : "off"}
                      />
                    </span>
                  ) : null}
                </button>
                )}
                {pxeHostExpanded ? (
                  <>
                <p className="mb-3 mt-2 text-[12px] leading-snug" style={{ color: "var(--text2)" }}>
                  Add these as DHCP scope options on the site router, then turn on TFTP and HTTP below.
                </p>
                {!hasLanIp && (
                  <p className="mb-3 text-[12px] leading-snug" style={{ color: "var(--amber)" }}>
                    {!status
                      ? configError
                        ? `The sidecar did not answer: ${configError}`
                        : "Waiting for the sidecar to report adapters..."
                      : (status.lanIpHint ??
                        (adapters.length > 0
                          ? "Select the Ethernet adapter below - the default route is not a usable PXE address."
                          : "No usable IPv4 - plug in Ethernet and wait for DHCP. PXE needs a real LAN address."))}
                  </p>
                )}

                <div className="grid gap-3 lg:grid-cols-2">
                  <div className="flex flex-col gap-2">
                  <div className="overflow-x-auto rounded border" style={{ borderColor: "var(--border)" }}>
                    <table className="w-full min-w-0 text-left text-[12px]">
                      <thead>
                        <tr className="mono text-[10px] uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                          <th className="px-2 py-1.5 font-medium">Opt</th>
                          <th className="px-2 py-1.5 font-medium">Value</th>
                          <th className="px-2 py-1.5 font-medium w-14" />
                        </tr>
                      </thead>
                      <tbody className="mono text-[11px]">
                        <tr style={{ borderTop: "1px solid var(--border)" }}>
                          <td className="px-2 py-1.5 font-medium" style={{ color: "var(--accent2)" }}>
                            66
                          </td>
                          <td className="px-2 py-1.5" style={{ color: hasLanIp ? "var(--purple)" : "var(--amber)" }}>
                            {bootServerIp}
                          </td>
                          <td className="px-2 py-1.5">
                            <button
                              type="button"
                              className="btn py-0.5 text-[10px]"
                              disabled={!hasLanIp || busy}
                              onClick={() => void copyFieldValue("Option 66", bootServerIp)}
                            >
                              Copy
                            </button>
                          </td>
                        </tr>
                        <tr style={{ borderTop: "1px solid var(--border)" }}>
                          <td className="px-2 py-1.5 font-medium" style={{ color: "var(--accent2)" }}>
                            67
                          </td>
                          <td className="px-2 py-1.5" style={{ color: "var(--accent2)" }}>
                            {tftpBootFiles.length > 0 ? (
                              <select
                                className="mono max-w-full text-[11px]"
                                style={dirtyFieldOutline("tftpBootFile")}
                                value={bootFileName}
                                disabled={busy || loading || !!menuRebuildMessage}
                                onChange={(e) => onTftpBootFileChange(e.target.value)}
                              >
                                {tftpBootFiles.map((entry) => (
                                  <option key={entry.preset ? `preset-${entry.fileName}` : entry.fileName} value={entry.fileName}>
                                    {entry.displayLabel ?? entry.fileName}
                                    {!entry.preset && entry.missing ? " (missing)" : ""}
                                  </option>
                                ))}
                              </select>
                            ) : (
                              bootFileName
                            )}
                          </td>
                          <td className="px-2 py-1.5">
                            <button
                              type="button"
                              className="btn py-0.5 text-[10px]"
                              disabled={busy || !!menuRebuildMessage}
                              onClick={() => void copyFieldValue("Option 67", bootFileName)}
                            >
                              Copy
                            </button>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>

                  </div>

                  <div className="flex flex-col gap-2">
                    <label
                      className="flex flex-wrap items-center justify-between gap-2 rounded border px-2 py-1.5"
                      style={{ borderColor: "var(--border)", background: "var(--surface)" }}
                    >
                      <span className="flex min-w-0 flex-col gap-0.5">
                        <span className="text-[12px] font-medium" style={{ color: "var(--text)" }}>
                          TFTP
                        </span>
                        <span className="mono text-[10px]" style={{ color: "var(--text3)" }}>
                          Port 69 | {bootFileName}
                          {status?.platform === "macos" && !status?.tftpRunning
                            ? status?.macOsAdminCredentialCached
                              ? " | admin cached"
                              : status?.localMachineCredentialConfigured
                                ? " | saved in Credentials"
                                : " | admin for port 69"
                            : ""}
                        </span>
                      </span>
                      <span className="flex shrink-0 items-center gap-2">
                        {statusBadge(!!status?.tftpRunning, "TFTP")}
                        <input
                          type="checkbox"
                          checked={!!status?.tftpRunning}
                          disabled={busy || loading}
                          title="Start or stop TFTP"
                          onChange={(e) => void toggleTftp(e.target.checked)}
                        />
                      </span>
                    </label>
                    {!status?.tftpRunning && (status?.tftpLastError || status?.tftpPort69KillCommand) && (
                      <div
                        className="rounded border px-2 py-1.5 text-[11px] leading-snug"
                        style={{ borderColor: "var(--amber)", background: "var(--surface)" }}
                      >
                        <p style={{ color: "var(--amber)" }}>
                          {status.tftpPort69KillCommand ||
                          /already in use/i.test(status.tftpLastError ?? "")
                            ? "Port 69 already in use."
                            : /not granted|cancelled/i.test(status.tftpLastError ?? "")
                              ? "Administrator permission was not granted."
                              : "TFTP could not start."}
                        </p>
                        {(status.tftpPort69KillCommand || status.tftpElevatedCommand) && (
                          <button
                            type="button"
                            className="btn mt-1.5 py-0.5 text-[10px]"
                            disabled={busy || !!menuRebuildMessage}
                            onClick={() =>
                              void copyFieldValue(
                                status.tftpPort69KillCommand ? "TFTP kill commands" : "TFTP command",
                                status.tftpPort69KillCommand ?? status.tftpElevatedCommand!,
                              )
                            }
                          >
                            {status.tftpPort69KillCommand ? "Copy kill commands" : "Copy sudo command"}
                          </button>
                        )}
                      </div>
                    )}
                    {status?.platform === "macos" &&
                      !status?.macOsAdminCredentialCached &&
                      status?.localMachineCredentialConfigured && (
                      <div className="px-0.5 text-[10px]" style={{ color: "var(--text3)" }}>
                        Local administrator saved in Infrastructure credentials - loads automatically
                        when TFTP starts, or use Load session in that dialog.
                      </div>
                    )}
                    {status?.platform === "macos" && status?.macOsAdminCredentialCached && (
                      <div className="flex flex-wrap items-center gap-2 px-0.5 text-[10px]" style={{ color: "var(--text3)" }}>
                        <span>macOS admin password cached in memory for this session.</span>
                        <button
                          type="button"
                          className="btn py-0.5 text-[10px]"
                          disabled={busy || !!menuRebuildMessage}
                          onClick={() => void clearMacAdminCache()}
                        >
                          Forget password
                        </button>
                      </div>
                    )}
                    <label
                      className="flex flex-wrap items-center justify-between gap-2 rounded border px-2 py-1.5"
                      style={{ borderColor: "var(--border)", background: "var(--surface)" }}
                    >
                      <span className="flex min-w-0 flex-col gap-0.5">
                        <span className="text-[12px] font-medium" style={{ color: "var(--text)" }}>
                          HTTP
                        </span>
                        <span className="mono text-[10px]" style={{ color: "var(--text3)" }}>
                          Port {httpPort.trim() || "8080"} | wimboot + WIMs
                        </span>
                      </span>
                      <span className="flex shrink-0 items-center gap-2">
                        {statusBadge(!!status?.httpRunning, "HTTP")}
                        <input
                          type="checkbox"
                          checked={!!status?.httpRunning}
                          disabled={busy || loading}
                          title="Start or stop HTTP"
                          onChange={(e) => void toggleHttp(e.target.checked)}
                        />
                      </span>
                    </label>
                    {!status?.httpRunning && (status?.httpLastError || status?.httpPortKillCommand) && (
                      <div
                        className="rounded border px-2 py-1.5 text-[11px] leading-snug"
                        style={{ borderColor: "var(--amber)", background: "var(--surface)" }}
                      >
                        <p style={{ color: "var(--amber)" }}>
                          {status.httpPortKillCommand ||
                          /already in use/i.test(status.httpLastError ?? "")
                            ? `Port ${httpPort.trim() || "8080"} already in use.`
                            : status.httpLastError ?? "HTTP could not start."}
                        </p>
                        {status.httpPortKillCommand && (
                          <button
                            type="button"
                            className="btn mt-1.5 py-0.5 text-[10px]"
                            disabled={busy || !!menuRebuildMessage}
                            onClick={() => void copyFieldValue("HTTP kill commands", status.httpPortKillCommand!)}
                          >
                            Copy kill commands
                          </button>
                        )}
                      </div>
                    )}
                    {status?.tftpRunning && !status?.httpRunning && !status?.httpLastError && !status?.httpPortKillCommand && (
                      <div
                        className="rounded border px-2 py-1.5 text-[11px] leading-snug"
                        style={{ borderColor: "var(--amber)", background: "var(--surface)" }}
                      >
                        <p style={{ color: "var(--amber)" }}>
                          HTTP is off - clients cannot load the local boot menu. Turn HTTP on before booting.
                        </p>
                      </div>
                    )}
                    <label
                      className="flex flex-wrap items-center justify-between gap-2 rounded border px-2 py-1.5"
                      style={{
                        borderColor: hostFieldDirty("smbShareEnabled") ? "var(--amber)" : "var(--border)",
                        background: "var(--surface)",
                      }}
                      title={smbShareTooltip}
                    >
                      <span className="flex min-w-0 flex-col gap-0.5">
                        <span className="text-[12px] font-medium" style={{ color: "var(--text)" }}>
                          SMB
                        </span>
                        <span className="mono text-[10px]" style={{ color: "var(--text3)" }}>
                          {data?.smbShare?.shareName ?? "Deploy$"} | hidden, read-only
                          {data?.smbShare?.authUser ? ` | ${data.smbShare.authDomain ?? "WORKGROUP"}\\${data.smbShare.authUser}` : ""}
                        </span>
                      </span>
                      <span className="flex shrink-0 items-center gap-2">
                        <span
                          className="badge"
                          style={{
                            color: smbActive ? "var(--green)" : "var(--text3)",
                            borderColor: smbActive ? "var(--green-dim)" : "var(--border)",
                          }}
                        >
                          SMB: {smbActive ? "shared" : "off"}
                        </span>
                        <input
                          type="checkbox"
                          checked={smbShareEnabled}
                          disabled={busy || loading}
                          title="Share imaging library over SMB"
                          onChange={(e) => onSmbShareEnabledChange(e.target.checked)}
                        />
                      </span>
                    </label>
                    {smbShareEnabled && (data?.smbShare?.tccBlocked || data?.smbShare?.error) && (
                      <div
                        className="rounded border px-2 py-1.5 text-[11px] leading-snug"
                        style={{ borderColor: "var(--amber)", background: "var(--surface)" }}
                      >
                        <p style={{ color: "var(--amber)" }}>
                          {data?.smbShare?.tccBlocked ? "! " : null}
                          {data?.smbShare?.guidance || data?.smbShare?.error}
                        </p>
                        {data?.smbShare?.tccBlocked && (
                          <>
                            <p className="mt-1" style={{ color: "var(--text3)" }}>
                              Easiest fix: keep the root under ~/Public. To insist on this folder, grant
                              Full Disk Access to <span className="mono">/usr/sbin/smbd</span> (the share
                              is served by smbd, not this app), then Start Imaging Services again.
                            </p>
                            <button
                              type="button"
                              className="btn mt-1.5 py-0.5 text-[10px]"
                              disabled={busy || !!menuRebuildMessage}
                              onClick={() => void openFullDiskAccessForSmbd()}
                            >
                              Open Full Disk Access + reveal smbd
                            </button>
                          </>
                        )}
                      </div>
                    )}
                    {hostFormDirty ? (
                      <div
                        className="rounded border px-2 py-2"
                        style={{ borderColor: "var(--amber)", background: "var(--surface)" }}
                      >
                        <p className="text-[11px] leading-snug" style={{ color: "var(--amber)" }}>
                          Unsaved: {dirtyHostSummary}. Apply once to rebuild PXE menus and refresh scope values.
                        </p>
                        <div className="mt-2 flex flex-wrap gap-2">
                          <button
                            type="button"
                            className="btn btn-primary py-0.5 text-[11px]"
                            disabled={busy || loading || !!menuRebuildMessage}
                            onClick={() => void applyHostFormChanges()}
                          >
                            Apply changes
                          </button>
                          <button
                            type="button"
                            className="btn py-0.5 text-[11px]"
                            disabled={busy || loading || !!menuRebuildMessage}
                            onClick={cancelHostFormChanges}
                          >
                            Cancel changes
                          </button>
                        </div>
                      </div>
                    ) : null}
                  </div>
                </div>

                {hasLanIp && status?.httpUrl && (
                  <p className="mono mt-2 text-[10px]" style={{ color: "var(--text3)" }}>
                    {status.httpUrl}
                  </p>
                )}

                <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
                  <label className="flex flex-col gap-1">
                    <span className="mono text-[10px]" style={dirtyLabelStyle("interfaceId")}>
                      Ethernet adapter
                    </span>
                    <select
                      className="input-box mono h-[26px] text-[11px]"
                      style={dirtyFieldOutline("interfaceId")}
                      value={interfaceId}
                      disabled={busy || loading}
                      onChange={(e) => onInterfaceIdChange(e.target.value)}
                    >
                      {adapters.length === 0 ? (
                        <option value="" disabled>
                          {status ? "No usable IPv4 adapters" : "Waiting for sidecar..."}
                        </option>
                      ) : (
                        <>
                          <option value="">Default route adapter</option>
                          {adapters.map((a) => (
                            <option key={a.id} value={a.id}>
                              {a.description || a.name} ({a.ipv4.join(", ")})
                            </option>
                          ))}
                        </>
                      )}
                    </select>
                  </label>
                  <label className="flex flex-col gap-1">
                    <span className="mono text-[10px]" style={dirtyLabelStyle("httpPort")}>
                      HTTP port
                    </span>
                    <input
                      className="input-box mono h-[26px] text-[11px] leading-none"
                      style={dirtyFieldOutline("httpPort")}
                      value={httpPort}
                      disabled={busy || loading}
                      onChange={(e) => onHttpPortChange(e.target.value)}
                    />
                  </label>
                  <label className="flex flex-col gap-1">
                    <span className="mono text-[10px]" style={dirtyLabelStyle("tftpMode")}>
                      TFTP mode
                    </span>
                    <select
                      className="input-box mono h-[26px] text-[11px]"
                      style={dirtyFieldOutline("tftpMode")}
                      value={tftpMode}
                      disabled={busy || loading}
                      title="Router DHCP: site DHCP serves options 66/67. ProxyDHCP: Hyper-V / isolated lab on an external vSwitch or bridged NIC (Default Switch VMs will not PXE boot). Standalone: this host runs DHCP."
                      onChange={(e) => onTftpModeChange(e.target.value as "router" | "standalone" | "proxy")}
                    >
                      <option value="router">Router DHCP</option>
                      <option value="standalone">Standalone</option>
                      <option value="proxy">ProxyDHCP</option>
                    </select>
                  </label>
                  {status?.platform === "windows" && (
                    <label className="flex flex-col gap-1 sm:col-span-2 lg:col-span-3">
                      <span className="mono text-[10px]" style={dirtyLabelStyle("tftpd64Path")}>
                        Tftpd64 path
                      </span>
                      <input
                        className="input-box mono text-[11px]"
                        style={dirtyFieldOutline("tftpd64Path")}
                        placeholder="C:\Program Files\Tftpd64\Tftpd64.exe"
                        value={tftpd64Path}
                        disabled={busy || loading}
                        onChange={(e) => onTftpd64PathChange(e.target.value)}
                      />
                    </label>
                  )}
                </div>
                  </>
                ) : null}
              </section>
              )}

              {show("pxeLog") && (
              <section className="rounded-sm border p-3" style={{ borderColor: "var(--border)", background: "var(--surface2)" }}>
                {!solo && (
                <button
                  type="button"
                  className="flex w-full items-center gap-2 text-left"
                  aria-expanded={logExpanded}
                  onClick={() => setLogExpanded((open) => !open)}
                >
                  <h3 className="mono text-[10px] font-medium uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                    PXE activity log
                  </h3>
                  <span className="mono ml-auto flex shrink-0 items-center gap-2 text-[10px]" style={{ color: "var(--text3)" }}>
                    {logExpanded ? (
                      <SessionDot label="live" state={serviceDotState(true)} message="updating every 3s" />
                    ) : (
                      "TFTP requests"
                    )}
                  </span>
                </button>
                )}
                {logExpanded ? (
                  <div className="mt-3">
                    <div className="mb-2 flex items-center gap-2">
                      <p className="text-[11px]" style={{ color: "var(--text3)" }}>
                        Live TFTP requests from dnsmasq - which client fetched which boot file. Last{" "}
                        {logTail?.lines?.length ?? 0} lines.
                      </p>
                      <button
                        type="button"
                        className="btn ml-auto py-0.5 text-[10px]"
                        disabled={logLoading}
                        onClick={() => void refreshLog()}
                      >
                        {logLoading ? "Refreshing..." : "Refresh"}
                      </button>
                      <button
                        type="button"
                        className="btn btn-danger py-0.5 text-[10px]"
                        disabled={!logTail?.available || (logTail?.lines?.length ?? 0) === 0}
                        title="Truncate the dnsmasq/TFTP activity log on this host"
                        onClick={() => void clearPxeLog()}
                      >
                        Clear log
                      </button>
                    </div>
                    <div className="rounded border" style={{ borderColor: "var(--border)", background: "#05080d" }}>
                      <div
                        className="flex items-center justify-between gap-2 border-b px-3 py-2 text-[10px] uppercase tracking-wide"
                        style={{ borderColor: "var(--border)", color: "var(--text3)" }}
                      >
                        <span>TFTP log</span>
                        {logTail?.path ? (
                          <span className="mono truncate normal-case" style={{ color: "var(--text3)" }}>
                            {logTail.path}
                          </span>
                        ) : null}
                      </div>
                      <pre
                        className="max-h-[280px] min-h-[160px] overflow-auto p-3 text-[11px] leading-relaxed"
                        style={{ color: "#b7f7c4", whiteSpace: "pre-wrap", wordBreak: "break-word" }}
                      >
                        {logTail && logTail.available
                          ? logTail.lines.length > 0
                            ? logTail.lines.join("\n")
                            : "(log file is empty - start TFTP, then PXE-boot a client)"
                          : '(no TFTP log yet - start TFTP under "PXE on this host")'}
                      </pre>
                    </div>
                  </div>
                ) : null}
              </section>
              )}

              {show("imagingClients") && (
              <section className="rounded-sm border p-3" style={{ borderColor: "var(--border)", background: "var(--surface2)" }}>
                {!solo && (
                <button
                  type="button"
                  className="flex w-full items-center gap-2 text-left"
                  aria-expanded={imagingExpanded}
                  onClick={() => setImagingExpanded((open) => !open)}
                >
                  <h3 className="mono text-[10px] font-medium uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                    Imaging clients
                  </h3>
                  <span className="mono ml-auto flex shrink-0 items-center gap-2 text-[10px]" style={{ color: "var(--text3)" }}>
                    {imagingExpanded ? (
                      <SessionDot label="live" state={serviceDotState(true)} message="updating every 5s" />
                    ) : (status?.imagingClientsActive ?? 0) > 0 ? (
                      <span style={{ color: "var(--green)" }}>{status?.imagingClientsActive} imaging</span>
                    ) : (
                      "device logs"
                    )}
                  </span>
                </button>
                )}
                {imagingExpanded ? (
                  <div className="mt-3">
                    <div className="mb-2 flex items-center gap-2">
                      <p className="text-[11px]" style={{ color: "var(--text3)" }}>
                        Devices running a deploy client push their deployment log here live - select one to tail it.
                      </p>
                      <button
                        type="button"
                        className="btn ml-auto py-0.5 text-[10px]"
                        disabled={imagingLoading}
                        onClick={() => void refreshImagingClients()}
                      >
                        {imagingLoading ? "Refreshing..." : "Refresh"}
                      </button>
                      <button
                        type="button"
                        className="btn btn-danger py-0.5 text-[10px]"
                        disabled={(imagingClients?.length ?? 0) === 0}
                        title="Remove all stored imaging logs on this host"
                        onClick={() => void clearImagingLogs()}
                      >
                        Clear
                      </button>
                    </div>
                    {(imagingClients?.length ?? 0) === 0 ? (
                      <p className="px-1 py-4 text-center text-[12px]" style={{ color: "var(--text3)" }}>
                        No imaging clients yet - devices appear here once a client starts logging.
                      </p>
                    ) : (
                      <DataTable
                        columns={imagingColumns}
                        rows={imagingClients ?? []}
                        rowKey={(r) => r.serial}
                        selectedId={imagingSelected}
                        onRowClick={(r) => {
                          setImagingLog(null);
                          setImagingSelected((current) => (current === r.serial ? null : r.serial));
                        }}
                      />
                    )}
                    {imagingSelected ? (
                      <div className="mt-3 rounded border" style={{ borderColor: "var(--border)", background: "#05080d" }}>
                        <div
                          className="flex items-center justify-between gap-2 border-b px-3 py-2 text-[10px] uppercase tracking-wide"
                          style={{ borderColor: "var(--border)", color: "var(--text3)" }}
                        >
                          <span>Imaging log</span>
                          <span className="mono truncate normal-case" style={{ color: "var(--text3)" }}>
                            {imagingSelected}
                          </span>
                        </div>
                        <pre
                          className="max-h-[280px] min-h-[120px] overflow-auto p-3 text-[11px] leading-relaxed"
                          style={{ color: "#b7f7c4", whiteSpace: "pre-wrap", wordBreak: "break-word" }}
                        >
                          {imagingLog
                            ? imagingLog.available
                              ? imagingLog.lines.length > 0
                                ? imagingLog.lines.join("\n")
                                : "(log is empty)"
                              : "(no log stored for this device)"
                            : "Loading..."}
                        </pre>
                      </div>
                    ) : null}
                  </div>
                ) : null}
              </section>
              )}

              {show("bootImages") && (
              <section className="rounded-sm border p-3" style={{ borderColor: "var(--border)", background: "var(--surface2)" }}>
                <h3 className="mono mb-2 text-[10px] font-medium uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                  Boot WIMs
                </h3>
                <div className="mb-3 flex items-center gap-2 text-[12px]">
                  <input
                    type="radio"
                    name="pxe-default-wim"
                    checked={!wims.some((w) => w.isDefault)}
                    disabled={busy || !!menuRebuildMessage || wims.length === 0}
                    onChange={() => void clearDefaultWim()}
                  />
                  <span style={{ color: "var(--text2)" }}>No default</span>
                </div>
                <div className="mb-3 flex flex-wrap gap-2">
                  <button className="btn" type="button" disabled={busy || loading} onClick={() => void importWim()}>
                    Add WIM...
                  </button>
                  <button className="btn" type="button" disabled={busy || loading} onClick={() => void extractWimFromIso()}>
                    Extract WIM from ISO...
                  </button>
                  <button className="btn" type="button" disabled={loading} onClick={() => void openWimFolder()}>
                    Open WIM folder
                  </button>
                </div>
                {wims.length === 0 ? (
                  <p className="text-[12px]" style={{ color: "var(--text2)" }}>
                    No boot WIMs - use Add WIM... to import one.
                  </p>
                ) : (
                  <DataTable columns={wimColumns} rows={wims} rowKey={(r) => r.fileName} />
                )}
              </section>
              )}

              {show("taskSequences") && (
              <section className="rounded-sm border p-3" style={{ borderColor: "var(--border)", background: "var(--surface2)" }}>
                {!solo && (
                <button
                  type="button"
                  className="flex w-full items-center gap-2 text-left"
                  aria-expanded={tsExpanded}
                  onClick={() => setTsExpanded((open) => !open)}
                >
                  <h3 className="mono text-[10px] font-medium uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                    Task sequences
                  </h3>
                  <span className="mono ml-auto shrink-0 text-[10px]" style={{ color: "var(--text3)" }}>
                    {tsPayload
                      ? `${tsPayload.publishedFiles.length} published`
                      : "first-boot unattends"}
                  </span>
                </button>
                )}
                {tsExpanded ? (
                  <div className="mt-3">
                    <div className="mb-3 flex items-center gap-2">
                      <p
                        className="text-[11px]"
                        style={{ color: "var(--text3)" }}
                        title={
                          "Published to TaskSequences/ in the deploy share - pick one in the deploy client's Task Sequence menu. " +
                          "{{SERIAL}} and the connect credentials fill on the device at deploy time, so no secrets are stored here."
                        }
                      >
                        Named first-boot setups the deploy client can apply after imaging.
                      </p>
                      <label
                        className="mono ml-auto flex items-center gap-1.5 text-[10px] uppercase tracking-wider"
                        style={{ color: "var(--text3)" }}
                        title="Preselected in the deploy client's Task Sequence menu at Connect - set one for touch-free deployments. The tech can still change it on the device."
                      >
                        Default at boot
                        <select
                          className="input-box mono h-[24px] normal-case tracking-normal text-[10px]"
                          value={tsDefaultId}
                          onChange={(e) => setTsDefaultId(e.target.value)}
                        >
                          <option value="">(none - clean OOBE)</option>
                          {(tsEdit ?? [])
                            .filter((s) => s.enabled)
                            .map((s) => (
                              <option key={s.id} value={s.id}>
                                {s.name}
                              </option>
                            ))}
                          {tsDefaultId && !(tsEdit ?? []).some((s) => s.enabled && s.id === tsDefaultId) ? (
                            <option value={tsDefaultId}>{tsDefaultId} (not published)</option>
                          ) : null}
                        </select>
                      </label>
                      <button
                        type="button"
                        className="btn py-0.5 text-[10px]"
                        disabled={!tsDirty || tsSaving || Boolean(tsValidationError)}
                        title={tsValidationError ?? undefined}
                        onClick={() => void saveTaskSequences()}
                      >
                        {tsSaving ? "Saving..." : "Save & publish"}
                      </button>

                    </div>
                    {(tsEdit ?? []).map((seq) => {
                      const published = tsPayload?.publishedFiles.includes(`${seq.id}.xml`) ?? false;
                      const selected = tsSelectedId === seq.id;
                      return (
                        <div
                          key={seq.id}
                          className="mb-2 rounded border"
                          style={{ borderColor: "var(--border)", background: "var(--surface)" }}
                        >
                          <div className="flex items-center gap-2 px-2 py-1.5">
                            <input
                              type="checkbox"
                              checked={seq.enabled}
                              title={seq.enabled ? "Published on save" : "Not published"}
                              onChange={(e) =>
                                setTsEdit((prev) =>
                                  (prev ?? []).map((s) => (s.id === seq.id ? { ...s, enabled: e.target.checked } : s)),
                                )
                              }
                            />
                            {selected ? (
                              <input
                                className="input-box mono h-[24px] flex-1 text-[12px]"
                                value={seq.name}
                                spellCheck={false}
                                onChange={(e) =>
                                  setTsEdit((prev) =>
                                    (prev ?? []).map((s) => (s.id === seq.id ? { ...s, name: e.target.value } : s)),
                                  )
                                }
                              />
                            ) : (
                              <button
                                type="button"
                                className="flex flex-1 items-center gap-2 text-left text-[12px]"
                                onClick={() => setTsSelectedId(seq.id)}
                              >
                                <span>{seq.name}</span>
                              </button>
                            )}
                            <span className="mono text-[10px]" style={{ color: "var(--text3)" }}>
                              {TS_KIND_LABELS[seq.kind] ?? seq.kind}
                            </span>
                            <span
                              className="mono text-[10px]"
                              style={{ color: published ? "var(--green)" : "var(--text3)" }}
                            >
                              {published ? "published" : seq.enabled ? "pending save" : "off"}
                            </span>
                            <button
                              type="button"
                              className="mono text-[10px]"
                              style={{ color: "var(--text3)" }}
                              title={selected ? "Collapse" : "Edit fields"}
                              onClick={() => setTsSelectedId(selected ? null : seq.id)}
                            >
                              {selected ? "v" : ">"}
                            </button>
                            <button
                              type="button"
                              className="btn btn-danger px-1.5 py-0 text-[10px]"
                              title="Remove this sequence (applies on Save & publish)"
                              onClick={() =>
                                setTsEdit((prev) => (prev ?? []).filter((s) => s.id !== seq.id))
                              }
                            >
                              x
                            </button>
                          </div>
                          {selected ? (
                            <div
                              className="grid grid-cols-[140px_1fr] items-center gap-x-3 gap-y-1.5 border-t px-3 py-2"
                              style={{ borderColor: "var(--border)" }}
                            >
                              <label className="text-[11px]" style={{ color: "var(--text2)" }}>
                                Role
                              </label>
                              <select
                                className="input-box mono h-[26px] text-[11px]"
                                value={seq.kind}
                                onChange={(e) => {
                                  const kind = e.target.value;
                                  const roleDefaults = tsPayload?.roleDefaults ?? {};
                                  setTsEdit((prev) =>
                                    (prev ?? []).map((s) => {
                                      if (s.id !== seq.id) return s;
                                      const fields = { ...s.fields };
                                      // Empty key publishes the role default; swap only a
                                      // value that still equals the other role's default
                                      // (defaults come from the sidecar's GSV catalog).
                                      const oldDefault = s.kind === "server" ? roleDefaults.server : roleDefaults.client;
                                      if (oldDefault && fields.productKey === oldDefault) fields.productKey = "";
                                      return { ...s, kind, fields };
                                    }),
                                  );
                                }}
                              >
                                <option value="client">Client</option>
                                <option value="server">Server</option>
                              </select>
                              <label
                                className="text-[11px]"
                                style={{ color: "var(--text2)" }}
                                title="The install.wim this sequence deploys. Blank leaves the choice to whoever is standing at the device."
                              >
                                Windows image
                              </label>
                              <div className="flex items-center gap-1.5">
                                <select
                                  className="input-box mono h-[26px] flex-1 text-[11px]"
                                  value={seq.image ? `${seq.image.sourceId}||${seq.image.index}` : ""}
                                  onChange={(e) => {
                                    const raw = e.target.value;
                                    setTsEdit((prev) =>
                                      (prev ?? []).map((s) => {
                                        if (s.id !== seq.id) return s;
                                        if (!raw) {
                                          const { image: _drop, ...rest } = s;
                                          return rest as PxeBootTaskSequence;
                                        }
                                        const cut = raw.lastIndexOf("||");
                                        const sourceId = raw.slice(0, cut);
                                        const index = Number(raw.slice(cut + 2)) || 1;
                                        const entry = installImages.find((x) => x.id === sourceId);
                                        const img = entry?.images.find((i) => i.index === index);
                                        return {
                                          ...s,
                                          image: { sourceId, index, editionName: img?.name ?? "" },
                                        };
                                      }),
                                    );
                                  }}
                                >
                                  <option value="">(chosen at the device)</option>
                                  {installImages.map((entry) =>
                                    entry.imagesKnown && entry.images.length > 0 ? (
                                      <optgroup key={entry.id} label={entry.label}>
                                        {entry.images.map((img) => (
                                          <option key={`${entry.id}||${img.index}`} value={`${entry.id}||${img.index}`}>
                                            {img.name || img.edition || `Image ${img.index}`} (index {img.index})
                                          </option>
                                        ))}
                                      </optgroup>
                                    ) : (
                                      <option key={entry.id} value="" disabled>
                                        {entry.label} - editions not read yet
                                      </option>
                                    ),
                                  )}
                                  {seq.image &&
                                  !installImages.some(
                                    (x) =>
                                      x.id === seq.image?.sourceId &&
                                      x.images.some((i) => i.index === seq.image?.index),
                                  ) ? (
                                    <option value={`${seq.image.sourceId}||${seq.image.index}`}>
                                      {seq.image.editionName || `Index ${seq.image.index}`} (media offline)
                                    </option>
                                  ) : null}
                                </select>
                                {installImages.some((e) => !e.imagesKnown) ? (
                                  <button
                                    type="button"
                                    className="btn px-1.5 py-0 text-[10px]"
                                    disabled={installImagesBusy}
                                    title="Mount each ISO once and read its editions (cached afterwards)."
                                    onClick={() => void readInstallImageEditions()}
                                  >
                                    {installImagesBusy ? "Reading..." : "Read editions"}
                                  </button>
                                ) : null}
                              </div>
                              <span />
                              <label className="flex items-center gap-1.5 text-[11px]">
                                <input
                                  type="checkbox"
                                  checked={Boolean(seq.fields.joinDomain) || tsJoinOptIn.has(seq.id)}
                                  onChange={(e) => {
                                    const on = e.target.checked;
                                    setTsJoinOptIn((prev) => {
                                      const next = new Set(prev);
                                      if (on) next.add(seq.id);
                                      else next.delete(seq.id);
                                      return next;
                                    });
                                    if (!on) {
                                      // Turning it off clears the whole section rather than
                                      // leaving a half-configured join behind.
                                      setTsEdit((prev) =>
                                        (prev ?? []).map((s) =>
                                          s.id === seq.id
                                            ? { ...s, fields: { ...s.fields, joinDomain: "", machineOu: "", joinCredential: "" } }
                                            : s,
                                        ),
                                      );
                                    }
                                  }}
                                />
                                Join a domain
                              </label>
                              {TS_FIELD_ORDER
                                .filter((key) => key in seq.fields)
                                .filter((key) => {
                                  const joining = Boolean(seq.fields.joinDomain) || tsJoinOptIn.has(seq.id);
                                  if (["ipCidr", "gateway", "dns1"].includes(key))
                                    return seq.fields.network === "static";
                                  if (["joinDomain", "joinCredential", "machineOu"].includes(key)) return joining;
                                  return true;
                                })
                                .map((key) => {
                                const setField = (value: string) =>
                                  setTsEdit((prev) =>
                                    (prev ?? []).map((s) =>
                                      s.id === seq.id ? { ...s, fields: { ...s.fields, [key]: value } } : s,
                                    ),
                                  );
                                return (
                                  <Fragment key={key}>
                                    <label
                                      className="text-[11px]"
                                      style={{ color: "var(--text2)" }}
                                      title={
                                        key === "joinCredential"
                                          ? "Join credentials are filled in on the device at deploy time, or taken from a stored credential when one is selected - never written into the published file."
                                          : key === "computerName"
                                            ? "Free text. {{SERIAL}} fills on the device at deploy time."
                                            : undefined
                                      }
                                    >
                                      {TS_FIELD_LABELS[key] ?? key}
                                    </label>
                                    {key === "computerName" ? (
                                      <input
                                        className="input-box mono h-[26px] text-[11px]"
                                        value={seq.fields[key]}
                                        spellCheck={false}
                                        placeholder="{{SERIAL}}"
                                        title="Free text. {{SERIAL}} fills on the device from the BIOS serial (15-character NetBIOS limit applies)."
                                        onChange={(e) => setField(e.target.value)}
                                      />
                                    ) : key === "productKey" ? (
                                      <>
                                        <input
                                          className="input-box mono h-[26px] text-[11px]"
                                          value={seq.fields[key]}
                                          spellCheck={false}
                                          list={`pk-${seq.id}`}
                                          placeholder="blank = unlicensed / eval self-converts"
                                          title={
                                            "Leave blank for an evaluation image - the conversion step licenses it, and a key here would make Setup reject the answer file. " +
                                            "Otherwise type your MAK or retail key, or pick a GVLK suggestion. WDK does not KMS-activate."
                                          }
                                          onChange={(e) => setField(e.target.value.trim())}
                                        />
                                        <datalist id={`pk-${seq.id}`}>
                                          {(tsPayload?.kmsKeyOptions ?? [])
                                            .filter((o) =>
                                              seq.kind === "server" ? /server/i.test(o.label) : !/server/i.test(o.label),
                                            )
                                            .map((o) => (
                                              <option key={o.key} value={o.key}>
                                                {o.label}
                                              </option>
                                            ))}
                                        </datalist>
                                      </>
                                    ) : key === "network" ? (
                                      <select
                                        className="input-box mono h-[26px] text-[11px]"
                                        value={seq.fields[key]}
                                        onChange={(e) => setField(e.target.value)}
                                      >
                                        <option value="dhcp">DHCP</option>
                                        <option value="static">Static IP</option>
                                      </select>
                                    ) : key === "joinCredential" ? (
                                      <div className="flex flex-col gap-1">
                                        <div className="flex items-center gap-1.5">
                                          <select
                                            className="input-box mono h-[26px] flex-1 text-[11px]"
                                            value={seq.fields[key]}
                                            onChange={(e) => setField(e.target.value)}
                                          >
                                            <option value="">Fill at deploy time</option>
                                            {vaultSecretNames.length > 0 ? (
                                              <optgroup label="From the vault">
                                                {vaultSecretNames.map((n) => (
                                                  <option key={`vault:${n}`} value={`vault:${n}`}>
                                                    {n}
                                                  </option>
                                                ))}
                                              </optgroup>
                                            ) : null}
                                            {(tsPayload?.credentialOptions ?? []).length > 0 ? (
                                              <optgroup label="Credential store">
                                                {(tsPayload?.credentialOptions ?? []).map((c) => (
                                                  <option key={c.id} value={c.id}>
                                                    {c.label}
                                                    {c.loginName ? ` (${c.loginName})` : ""}
                                                  </option>
                                                ))}
                                              </optgroup>
                                            ) : null}
                                          </select>
                                          <button
                                            type="button"
                                            className="btn px-1.5 py-0 text-[10px]"
                                            title="Add, replace or delete secrets in the vault"
                                            onClick={() => setVaultEditor({ open: true, seqId: seq.id })}
                                          >
                                            Vault...
                                          </button>
                                        </div>
                                        <span className="text-[10px]" style={{ color: "var(--text3)" }}>
                                          {seq.fields[key]
                                            ? "Resolved when the sequence is published; the password is written into the unattend on the share."
                                            : "Nothing is stored: the tokens stay literal and the device fills them from whoever starts the deployment."}
                                        </span>
                                      </div>
                                    ) : key === "joinDomain" ? (
                                      (() => {
                                        // Suggestions come from this host's DNS search suffixes;
                                        // "verified" means the domain publishes the AD
                                        // domain-controller SRV record.
                                        const suggestions = tsPayload?.joinDomainSuggestions ?? [];
                                        return (
                                          <div className="flex flex-col gap-1">
                                            <input
                                              className="input-box mono h-[26px] text-[11px]"
                                              value={seq.fields[key]}
                                              spellCheck={false}
                                              list={`join-domains-${seq.id}`}
                                              placeholder="corp.example.com"
                                              title="The domain to join. Suggestions come from this machine's DNS."
                                              onChange={(e) => setField(e.target.value)}
                                            />
                                            <datalist id={`join-domains-${seq.id}`}>
                                              {suggestions.map((s) => (
                                                <option key={s.domain} value={s.domain} />
                                              ))}
                                            </datalist>
                                            {suggestions.length > 0 && !seq.fields[key] ? (
                                              <span className="flex flex-wrap items-center gap-1 text-[10px]" style={{ color: "var(--text3)" }}>
                                                From DNS:
                                                {suggestions.slice(0, 3).map((s) => (
                                                  <button
                                                    key={s.domain}
                                                    type="button"
                                                    className="btn px-1 py-0 text-[10px]"
                                                    title={
                                                      s.verified
                                                        ? "Publishes the Active Directory domain-controller SRV record"
                                                        : "A DNS search suffix on this machine - no AD domain-controller record found"
                                                    }
                                                    onClick={() => setField(s.domain)}
                                                  >
                                                    {s.domain}
                                                    {s.verified ? " (AD)" : ""}
                                                  </button>
                                                ))}
                                              </span>
                                            ) : null}
                                          </div>
                                        );
                                      })()
                                    ) : key === "machineOu" ? (
                                      <input
                                        className="input-box mono h-[26px] text-[11px]"
                                        value={seq.fields[key]}
                                        spellCheck={false}
                                        disabled={!seq.fields.joinDomain}
                                        placeholder="OU=Workstations,DC=corp,DC=example,DC=com"
                                        title="Where the computer object lands. Blank uses the domain's default Computers container."
                                        onChange={(e) => setField(e.target.value)}
                                      />
                                    ) : key === "dns1" ? (
                                      (() => {
                                        const values = [seq.fields.dns1 ?? "", seq.fields.dns2 ?? "", seq.fields.dns3 ?? ""];
                                        const nonEmpty = values.filter((v) => v.trim()).length;
                                        const visible = Math.min(3, Math.max(1, tsDnsVisible[seq.id] ?? nonEmpty));
                                        const setDns = (list: string[]) =>
                                          setTsEdit((prev) =>
                                            (prev ?? []).map((s) =>
                                              s.id === seq.id
                                                ? {
                                                    ...s,
                                                    fields: {
                                                      ...s.fields,
                                                      dns1: list[0] ?? "",
                                                      dns2: list[1] ?? "",
                                                      dns3: list[2] ?? "",
                                                    },
                                                  }
                                                : s,
                                            ),
                                          );
                                        return (
                                          <div className="flex flex-col gap-1">
                                            {Array.from({ length: visible }, (_, i) => (
                                              <div key={i} className="flex items-center gap-1">
                                                <input
                                                  className="input-box mono h-[26px] flex-1 text-[11px]"
                                                  style={tsFieldOutline(seq.id, `dns${i + 1}`)}
                                                  value={values[i]}
                                                  spellCheck={false}
                                                  placeholder={i === 0 ? "10.x.x.x (required)" : "10.x.x.x"}
                                                  onChange={(e) => {
                                                    const next = [...values];
                                                    next[i] = e.target.value;
                                                    setDns(next);
                                                  }}
                                                />
                                                {visible > 1 ? (
                                                  <button
                                                    type="button"
                                                    className="mono px-1 text-[12px]"
                                                    style={{ color: "var(--text3)" }}
                                                    title="Remove this DNS server"
                                                    onClick={() => {
                                                      const next = values.filter((_, j) => j !== i);
                                                      while (next.length < 3) next.push("");
                                                      setDns(next);
                                                      setTsDnsVisible((prev) => ({ ...prev, [seq.id]: visible - 1 }));
                                                    }}
                                                  >
                                                    -
                                                  </button>
                                                ) : null}
                                                {i === visible - 1 && visible < 3 ? (
                                                  <button
                                                    type="button"
                                                    className="mono px-1 text-[12px]"
                                                    style={{ color: "var(--text3)" }}
                                                    title="Add another DNS server"
                                                    onClick={() =>
                                                      setTsDnsVisible((prev) => ({ ...prev, [seq.id]: visible + 1 }))
                                                    }
                                                  >
                                                    +
                                                  </button>
                                                ) : null}
                                              </div>
                                            ))}
                                          </div>
                                        );
                                      })()
                                    ) : (
                                      <input
                                        className="input-box mono h-[26px] text-[11px]"
                                        style={tsFieldOutline(seq.id, key)}
                                        value={seq.fields[key]}
                                        spellCheck={false}
                                        onChange={(e) => setField(e.target.value)}
                                      />
                                    )}
                                  </Fragment>
                                );
                              })}
                            </div>
                          ) : null}
                          {selected && seq.fields.joinDomain && /education\.vic\.gov\.au$/i.test(seq.fields.joinDomain) ? (
                            <div className="border-t px-3 py-2" style={{ borderColor: "var(--border)" }}>
                              <div className="mb-1.5 flex items-center gap-2">
                                <span className="mono text-[10px] uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                                  Admin groups
                                </span>
                                <select
                                  className="input-box mono ml-auto h-[24px] text-[10px]"
                                  value=""
                                  title="Added to local Administrators at first boot"
                                  onChange={(e) => {
                                    const g = e.target.value;
                                    if (!g) return;
                                    setTsEdit((prev) =>
                                      (prev ?? []).map((s) =>
                                        s.id === seq.id && !(s.adminGroups ?? []).includes(g)
                                          ? { ...s, adminGroups: [...(s.adminGroups ?? []), g] }
                                          : s,
                                      ),
                                    );
                                  }}
                                >
                                  <option value="">+ add group...</option>
                                  {(tsPayload?.adminGroupOptions ?? [])
                                    .filter((g) => !(seq.adminGroups ?? []).includes(g))
                                    .map((g) => (
                                      <option key={g} value={g}>
                                        {g}
                                      </option>
                                    ))}
                                </select>
                              </div>
                              {(seq.adminGroups ?? []).length === 0 ? (
                                <p className="text-[11px]" style={{ color: "var(--text3)" }}>
                                  None - no domain groups added to Administrators.
                                </p>
                              ) : (
                                <div className="flex flex-wrap gap-1.5">
                                  {(seq.adminGroups ?? []).map((g) => (
                                    <span
                                      key={g}
                                      className="mono inline-flex items-center gap-1 rounded border px-1.5 py-0.5 text-[10px]"
                                      style={{ borderColor: "var(--border)", color: "var(--text2)" }}
                                    >
                                      {g}
                                      <button
                                        type="button"
                                        style={{ color: "var(--text3)" }}
                                        onClick={() =>
                                          setTsEdit((prev) =>
                                            (prev ?? []).map((s) =>
                                              s.id === seq.id
                                                ? { ...s, adminGroups: (s.adminGroups ?? []).filter((x) => x !== g) }
                                                : s,
                                            ),
                                          )
                                        }
                                      >
                                        x
                                      </button>
                                    </span>
                                  ))}
                                </div>
                              )}
                            </div>
                          ) : null}
                          {selected ? (
                            <div
                              className="flex flex-wrap items-center gap-2 border-t px-3 py-2"
                              style={{ borderColor: "var(--border)" }}
                            >
                              <span className="text-[10px]" style={{ color: tsDirty ? "var(--amber)" : "var(--text3)" }}>
                                {tsDirty ? "Unsaved changes" : published ? "Published" : "Saved"}
                              </span>
                              <button
                                type="button"
                                className="btn btn-primary ml-auto px-2 py-0.5 text-[11px]"
                                disabled={!tsDirty || tsSaving || Boolean(tsValidationError)}
                                title={tsValidationError ?? "Write the sequence and publish it to the deploy share"}
                                onClick={() => void saveTaskSequences()}
                              >
                                {tsSaving ? "Saving..." : "Save & publish"}
                              </button>
                            </div>
                          ) : null}
                          {selected ? (
                            (() => {
                              const account = seq.localAccount ?? {
                                enabled: false,
                                name: "localadmin",
                                displayName: "Local Admin",
                                group: "Administrators",
                                mode: "none",
                                passwordSource: "manual",
                                vaultSecret: "",
                                autoLogon: false,
                              };
                              const mode =
                                account.mode ??
                                (account.enabled ? (account.passwordSource === "vault" ? "vault" : "manual") : "none");
                              const patchAccount = (patch: Partial<typeof account>) =>
                                setTsEdit((prev) =>
                                  (prev ?? []).map((s) =>
                                    s.id === seq.id ? { ...s, localAccount: { ...account, ...patch } } : s,
                                  ),
                                );
                              const hasStoredPassword = Boolean(seq.localAccount?.password);
                              return (
                                <div className="border-t px-3 py-2" style={{ borderColor: "var(--border)" }}>
                                  <div className="flex items-center gap-2">
                                    <span className="mono text-[10px] uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                                      Local account
                                    </span>
                                    <select
                                      className="input-box h-[24px] text-[11px]"
                                      value={mode}
                                      onChange={(e) => patchAccount({ mode: e.target.value })}
                                    >
                                      <option value="none">No local account</option>
                                      <option value="manual">Manual account</option>
                                      <option value="vault">Account from the vault</option>
                                    </select>
                                    <span className="text-[10px]" style={{ color: "var(--text3)" }}>
                                      created at first boot
                                    </span>
                                  </div>
                                  {mode === "manual" ? (
                                    <div className="mt-1.5 flex flex-col gap-1.5">
                                      <div className="flex flex-wrap items-center gap-1.5">
                                        <input
                                          className="input-box h-[24px] w-[9rem] text-[11px]"
                                          placeholder="User name"
                                          value={account.name ?? ""}
                                          onChange={(e) => patchAccount({ name: e.target.value })}
                                        />
                                        <input
                                          type="password"
                                          className="input-box h-[24px] min-w-[12rem] text-[11px]"
                                          placeholder={hasStoredPassword ? "Stored - type to replace" : "Password"}
                                          style={tsFieldOutline(seq.id, "account:password")}
                                          value={account.passwordPlain ?? ""}
                                          onChange={(e) => patchAccount({ passwordPlain: e.target.value })}
                                        />
                                        <select
                                          className="input-box h-[24px] text-[11px]"
                                          value={account.group ?? "Administrators"}
                                          onChange={(e) => patchAccount({ group: e.target.value })}
                                        >
                                          <option value="Administrators">Administrators</option>
                                          <option value="Users">Users</option>
                                        </select>
                                      </div>
                                      <label className="flex items-center gap-1.5 text-[11px]">
                                        <input
                                          type="checkbox"
                                          checked={Boolean(account.autoLogon)}
                                          onChange={(e) => patchAccount({ autoLogon: e.target.checked })}
                                        />
                                        Auto sign-in as this user after imaging (survives one reboot)
                                      </label>
                                      <p className="text-[10px]" style={{ color: "var(--text3)" }}>
                                        Stored obfuscated, and written to the unattend with Windows&apos; own base64 scheme - not encryption. Fine where LAPS rotates the account.
                                      </p>
                                    </div>
                                  ) : mode === "vault" ? (
                                    <div className="mt-1.5 flex flex-col gap-1.5">
                                      <div className="flex flex-wrap items-center gap-1.5">
                                        <input
                                          className="input-box h-[24px] min-w-[16rem] text-[11px]"
                                          placeholder="Vault credential (user + password)"
                                          list={`acctvault-${seq.id}`}
                                          style={tsFieldOutline(seq.id, "account:vaultSecret")}
                                          value={account.vaultSecret ?? ""}
                                          onChange={(e) => patchAccount({ vaultSecret: e.target.value })}
                                        />
                                        <datalist id={`acctvault-${seq.id}`}>
                                          {vaultSecretNames.map((n) => (
                                            <option key={n} value={n} />
                                          ))}
                                        </datalist>
                                        <select
                                          className="input-box h-[24px] text-[11px]"
                                          value={account.group ?? "Administrators"}
                                          onChange={(e) => patchAccount({ group: e.target.value })}
                                        >
                                          <option value="Administrators">Administrators</option>
                                          <option value="Users">Users</option>
                                        </select>
                                      </div>
                                      <label className="flex items-center gap-1.5 text-[11px]">
                                        <input
                                          type="checkbox"
                                          checked={Boolean(account.autoLogon)}
                                          onChange={(e) => patchAccount({ autoLogon: e.target.checked })}
                                        />
                                        Auto sign-in as this user after imaging (survives one reboot)
                                      </label>
                                      <p className="text-[10px]" style={{ color: "var(--text3)" }}>
                                        The user name and password both come from the selected vault credential, read only when the sequence is published - never stored in the sequence.
                                      </p>
                                    </div>
                                  ) : null}
                                </div>
                              );
                            })()
                          ) : null}
                          {selected ? (
                            <div className="border-t px-3 py-2" style={{ borderColor: "var(--border)" }}>
                              <div className="mb-1.5 flex items-center gap-2">
                                <span className="mono text-[10px] uppercase tracking-wider" style={{ color: "var(--text3)" }}>
                                  First-boot steps
                                </span>
                                <span className="ml-auto flex gap-1">
                                  {(
                                    [
                                      ["reg", "+ Reg key"],
                                      ["cmd", "+ Command"],
                                      ["pwsh", "+ PowerShell"],
                                    ] as const
                                  ).map(([t, label]) => (
                                    <button
                                      key={t}
                                      type="button"
                                      className="btn px-1.5 py-0 text-[10px]"
                                      disabled={(seq.steps?.length ?? 0) >= 32}
                                      onClick={() =>
                                        setTsEdit((prev) =>
                                          (prev ?? []).map((s) =>
                                            s.id === seq.id
                                              ? {
                                                  ...s,
                                                  steps: [
                                                    ...(s.steps ?? []),
                                                    t === "reg"
                                                      ? { _key: `s${tsStepKeyCounter++}`, type: "reg", description: "", op: "add", path: "", name: "", valueType: "REG_SZ", data: "" }
                                                      : { _key: `s${tsStepKeyCounter++}`, type: t, description: "", command: "" },
                                                  ],
                                                }
                                              : s,
                                          ),
                                        )
                                      }
                                    >
                                      {label}
                                    </button>
                                  ))}
                                </span>
                              </div>
                              {stepLibrary ? (
                                (() => {
                                  const pick = libraryPick[seq.id] ?? { entryId: "", value: "" };
                                  const entries = libraryFor(seq.kind);
                                  const entry = entries.find((e) => e.id === pick.entryId);
                                  const categories = Array.from(new Set(entries.map((e) => e.category)));
                                  return (
                                    <div className="mb-1.5 flex flex-col gap-1">
                                      <div className="flex flex-wrap items-center gap-1.5">
                                        <span className="text-[10px]" style={{ color: "var(--text3)" }}>
                                          Add a common setting
                                        </span>
                                        <select
                                          className="input-box h-[24px] max-w-[16rem] text-[11px]"
                                          value={pick.entryId}
                                          onChange={(e) =>
                                            setLibraryPick((prev) => ({
                                              ...prev,
                                              [seq.id]: { entryId: e.target.value, value: "" },
                                            }))
                                          }
                                        >
                                          <option value="">Choose...</option>
                                          {categories.map((cat) => (
                                            <optgroup key={cat} label={cat}>
                                              {entries
                                                .filter((e) => e.category === cat)
                                                .map((e) => (
                                                  <option key={e.id} value={e.id}>
                                                    {e.name}
                                                    {e.risk === "caution" ? " (caution)" : ""}
                                                  </option>
                                                ))}
                                            </optgroup>
                                          ))}
                                        </select>
                                        {entry?.parameter ? (
                                          entry.parameter.type === "choice" ? (
                                            <select
                                              className="input-box h-[24px] text-[11px]"
                                              value={pick.value || entry.parameter.default}
                                              onChange={(e) =>
                                                setLibraryPick((prev) => ({
                                                  ...prev,
                                                  [seq.id]: { entryId: pick.entryId, value: e.target.value },
                                                }))
                                              }
                                            >
                                              {(entry.parameter.choices ?? []).map((c) => (
                                                <option key={c} value={c}>
                                                  {c}
                                                </option>
                                              ))}
                                            </select>
                                          ) : (
                                            <input
                                              className="input-box h-[24px] min-w-[14rem] text-[11px]"
                                              placeholder={entry.parameter.label}
                                              value={pick.value || entry.parameter.default}
                                              onChange={(e) =>
                                                setLibraryPick((prev) => ({
                                                  ...prev,
                                                  [seq.id]: { entryId: pick.entryId, value: e.target.value },
                                                }))
                                              }
                                            />
                                          )
                                        ) : null}
                                        <button
                                          type="button"
                                          className="btn px-1.5 py-0 text-[10px]"
                                          disabled={!pick.entryId || libraryBusy || (seq.steps?.length ?? 0) >= 32}
                                          onClick={() => void addStepFromLibrary(seq.id, seq.kind)}
                                        >
                                          + Add
                                        </button>
                                        {entry ? (
                                          <a
                                            href={entry.source}
                                            target="_blank"
                                            rel="noreferrer"
                                            className="text-[10px]"
                                            style={{ color: "var(--text2)" }}
                                          >
                                            docs &gt;
                                          </a>
                                        ) : null}
                                      </div>
                                      {entry ? (
                                        <p className="text-[10px]" style={{ color: "var(--text3)" }}>
                                          {entry.description}
                                        </p>
                                      ) : null}
                                    </div>
                                  );
                                })()
                              ) : null}
                              {(seq.steps ?? []).length === 0 ? (
                                <p className="text-[11px]" style={{ color: "var(--text3)" }}>
                                  None - nothing runs at first boot beyond Windows setup itself.
                                </p>
                              ) : (
                                (seq.steps ?? []).map((step, idx) => {
                                  const updateStep = (patch: Partial<PxeBootTaskSequenceStep>) =>
                                    setTsEdit((prev) =>
                                      (prev ?? []).map((s) =>
                                        s.id === seq.id
                                          ? {
                                              ...s,
                                              steps: (s.steps ?? []).map((st, i) => (i === idx ? { ...st, ...patch } : st)),
                                            }
                                          : s,
                                      ),
                                    );
                                  const moveStep = (dir: -1 | 1) =>
                                    setTsEdit((prev) =>
                                      (prev ?? []).map((s) => {
                                        if (s.id !== seq.id) return s;
                                        const steps = [...(s.steps ?? [])];
                                        const j = idx + dir;
                                        if (j < 0 || j >= steps.length) return s;
                                        [steps[idx], steps[j]] = [steps[j], steps[idx]];
                                        return { ...s, steps };
                                      }),
                                    );
                                  return (
                                    <div
                                      key={step._key ?? String(idx)}
                                      className="mb-1.5 rounded border px-2 py-1.5"
                                      style={{ borderColor: "var(--border)" }}
                                    >
                                      <div className="mb-1 flex items-center gap-1.5">
                                        <span className="mono text-[10px]" style={{ color: "var(--text3)" }}>
                                          {idx + 1}
                                        </span>
                                        <span
                                          className="mono rounded border px-1 text-[9px] uppercase"
                                          style={{ borderColor: "var(--border)", color: "var(--text3)" }}
                                        >
                                          {step.type === "pwsh" ? "PowerShell" : step.type === "reg" ? "Reg" : "Cmd"}
                                        </span>
                                        <input
                                          className="input-box mono h-[22px] flex-1 text-[10px]"
                                          placeholder="Description..."
                                          value={step.description}
                                          spellCheck={false}
                                          onChange={(e) => updateStep({ description: e.target.value })}
                                        />
                                        <button type="button" className="mono text-[10px]" style={{ color: "var(--text3)" }} disabled={idx === 0} title="Move up" onClick={() => moveStep(-1)}>
                                          ^
                                        </button>
                                        <button type="button" className="mono text-[10px]" style={{ color: "var(--text3)" }} disabled={idx === (seq.steps?.length ?? 0) - 1} title="Move down" onClick={() => moveStep(1)}>
                                          v
                                        </button>
                                        <button
                                          type="button"
                                          className="mono text-[10px]"
                                          style={{ color: "var(--red, #c33)" }}
                                          title="Remove step"
                                          onClick={() =>
                                            setTsEdit((prev) =>
                                              (prev ?? []).map((s) =>
                                                s.id === seq.id
                                                  ? { ...s, steps: (s.steps ?? []).filter((_, i) => i !== idx) }
                                                  : s,
                                              ),
                                            )
                                          }
                                        >
                                          x
                                        </button>
                                      </div>
                                      {step.type === "reg" ? (
                                        <div className="flex flex-wrap items-center gap-1.5">
                                          <select
                                            className="input-box mono h-[22px] text-[10px]"
                                            value={step.op ?? "add"}
                                            onChange={(e) => updateStep({ op: e.target.value })}
                                          >
                                            <option value="add">add</option>
                                            <option value="delete">delete</option>
                                          </select>
                                          <input
                                            className="input-box mono h-[22px] min-w-[200px] flex-1 text-[10px]"
                                            placeholder="HKLM\Path\To\Key"
                                            value={step.path ?? ""}
                                            spellCheck={false}
                                            onChange={(e) => updateStep({ path: e.target.value })}
                                          />
                                          <input
                                            className="input-box mono h-[22px] w-[140px] text-[10px]"
                                            placeholder="Value name"
                                            value={step.name ?? ""}
                                            spellCheck={false}
                                            onChange={(e) => updateStep({ name: e.target.value })}
                                          />
                                          {(step.op ?? "add") === "add" ? (
                                            <>
                                              <select
                                                className="input-box mono h-[22px] text-[10px]"
                                                value={step.valueType ?? "REG_SZ"}
                                                onChange={(e) => updateStep({ valueType: e.target.value })}
                                              >
                                                {["REG_SZ", "REG_DWORD", "REG_QWORD", "REG_EXPAND_SZ", "REG_MULTI_SZ"].map((t) => (
                                                  <option key={t} value={t}>
                                                    {t}
                                                  </option>
                                                ))}
                                              </select>
                                              <input
                                                className="input-box mono h-[22px] w-[160px] text-[10px]"
                                                placeholder="Data"
                                                value={step.data ?? ""}
                                                spellCheck={false}
                                                onChange={(e) => updateStep({ data: e.target.value })}
                                              />
                                            </>
                                          ) : null}
                                        </div>
                                      ) : (
                                        <input
                                          className="input-box mono h-[22px] w-full text-[10px]"
                                          placeholder={step.type === "pwsh" ? "PowerShell command..." : "Command..."}
                                          value={step.command ?? ""}
                                          spellCheck={false}
                                          onChange={(e) => updateStep({ command: e.target.value })}
                                        />
                                      )}
                                    </div>
                                  );
                                })
                              )}
                            </div>
                          ) : null}
                        </div>
                      );
                    })}
                    <div className="mt-2 flex items-center gap-2">
                      <input
                        className="input-box mono h-[26px] flex-1 text-[11px]"
                        placeholder="New sequence name..."
                        value={tsNewName}
                        spellCheck={false}
                        onChange={(e) => setTsNewName(e.target.value)}
                      />
                      <button
                        type="button"
                        className="btn py-0.5 text-[10px]"
                        disabled={(tsEdit?.length ?? 0) >= 8}
                        onClick={() => {
                          const id = `custom-${Date.now().toString(36)}`;
                          setTsEdit((prev) => [
                            ...(prev ?? []),
                            {
                              id,
                              name: tsNewName.trim() || "New sequence",
                              kind: "client",
                              enabled: false,
                              fields: { ...TS_DEFAULT_FIELDS },
                              adminGroups: [],
                              steps: [],
                            },
                          ]);
                          setTsNewName("");
                          setTsSelectedId(id);
                        }}
                      >
                        New sequence
                      </button>
                    </div>
                  </div>
                ) : null}
              </section>
              )}
            </>
          )}
        </div>
      </PanelShell>

      <ConfirmModal
        open={!!replaceConfirm}
        title="Replace boot WIM?"
        subtitle={replaceConfirm?.fileName}
        confirmLabel="Yes"
        cancelLabel="No"
        body={
          <p className="text-[12px] leading-relaxed" style={{ color: "var(--text2)" }}>
            Would you like to replace the existing WIM{" "}
            <strong>{replaceConfirm?.fileName}</strong> with the file you selected?
          </p>
        }
        onCancel={() => setReplaceConfirm(null)}
        onConfirm={() => confirmReplaceWim()}
      />

      <ConfirmModal
        open={!!removeTarget}
        title="Remove boot WIM"
        subtitle={removeTarget?.fileName}
        danger
        confirmLabel="Remove"
        body={
          <p className="text-[12px] leading-relaxed" style={{ color: "var(--text2)" }}>
            Delete this boot image from the local PXE store? Targets using it will fail until another WIM is set as
            default.
          </p>
        }
        onCancel={() => setRemoveTarget(null)}
        onConfirm={() => confirmRemoveWim()}
      />

      <ConfirmModal
        open={!!isoWimPick}
        title="Choose a WIM to import"
        subtitle={isoWimPick?.isoFileName}
        confirmLabel="Import"
        cancelLabel="Cancel"
        body={
          <div className="flex flex-col gap-2">
            <p className="text-[12px] leading-relaxed" style={{ color: "var(--text2)" }}>
              This ISO contains more than one boot image. Pick which .wim to extract into the boot WIM store.
            </p>
            <select
              className="input-box mono text-[11px]"
              value={isoWimPick?.selected ?? ""}
              onChange={(e) => setIsoWimPick((prev) => (prev ? { ...prev, selected: e.target.value } : prev))}
            >
              {isoWimPick?.entries.map((entry) => (
                <option key={entry.path} value={entry.path}>
                  {entry.displayPath} ({formatFileSize(entry.sizeBytes)})
                </option>
              ))}
            </select>
          </div>
        }
        onCancel={() => setIsoWimPick(null)}
        onConfirm={() => confirmIsoWimPick()}
      />

      <ConfirmModal
        open={!!isoWimReplace}
        title="Replace boot WIM?"
        subtitle={isoWimReplace?.targetFileName}
        confirmLabel="Yes"
        cancelLabel="No"
        body={
          <p className="text-[12px] leading-relaxed" style={{ color: "var(--text2)" }}>
            A boot WIM named <strong>{isoWimReplace?.targetFileName}</strong> already exists. Replace it with the
            image extracted from this ISO?
          </p>
        }
        onCancel={() => setIsoWimReplace(null)}
        onConfirm={() => confirmIsoWimReplace()}
      />

      {menuRebuildMessage ? <PxeMenuRebuildOverlay message={menuRebuildMessage} /> : null}

      <VaultEditorOverlay
        open={vaultEditor.open}
        onClose={() => setVaultEditor({ open: false })}
        onChange={() => void loadVaultSecrets()}
        onPick={(secretName) => {
          const seqId = vaultEditor.seqId;
          if (!seqId) return;
          setTsEdit((prev) =>
            (prev ?? []).map((s) =>
              s.id === seqId ? { ...s, fields: { ...s.fields, joinCredential: `vault:${secretName}` } } : s,
            ),
          );
        }}
      />
      <InfrastructureCredentialsOverlay
        open={credentialsOpen}
        onClose={() => setCredentialsOpen(false)}
        onVaultChange={() => reloadConfig()}
      />
    </>
  );
}

function PxeMenuRebuildOverlay({ message }: { message: string }) {
  return createPortal(
    <div
      className="fixed inset-0 z-[220] flex items-center justify-center"
      style={{ background: "rgba(15, 17, 23, 0.72)" }}
      aria-live="polite"
      aria-busy="true"
    >
      <div
        className="mx-4 w-[min(440px,92vw)] rounded-md p-6 text-center"
        style={{
          background: "var(--surface)",
          border: "1px solid var(--border)",
          boxShadow: "0 12px 40px rgba(0, 0, 0, 0.35)",
        }}
      >
        <div className="cond mb-2 text-[16px] font-semibold" style={{ color: "var(--text)" }}>
          {message}
        </div>
        <div className="text-[12px] leading-relaxed" style={{ color: "var(--text2)" }}>
          Updating boot.ipxe and PXE menu files on disk. Do not change defaults again until this finishes.
        </div>
        <div
          className="mono mt-4 text-[10px] uppercase tracking-wider"
          style={{ color: "var(--text3)", letterSpacing: "0.12em" }}
        >
          Please wait
        </div>
      </div>
    </div>,
    document.body,
  );
}
