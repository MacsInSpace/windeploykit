// WinDeployKit sidecar wire types.
// Sliced from the USM original (486 declarations) to the set reachable from
// the panels and libs in this app. Regenerate by widening the imports, not by
// copying blocks back in.

export type SidecarEventName =
  | "ready"
  | "error"
  | "log"
  | "disconnected"
  | "pxe-caddy"
  | "pxe-tftpd64"
  | "aria2-tools"
  | "driver-download-progress"
  | "vendor-catalog-refresh"
  | "eval-iso-catalog-refresh"
  | "aria2-promote"
  | "exited";

export interface SidecarEvent<T = unknown> {
  event: SidecarEventName;
  data?: T;
}

export type SidecarErrorCode =
  | "UNKNOWN"
  | "PARSE_ERROR"
  | "SESSION_NOT_ESTABLISHED"
  | "DEPLOYKIT_ERROR"
  | "NO_RESULT"
  | "BAD_REQUEST"
  /** Sidecar not yet through init -- usually means it's waiting on SetCredentials. */
  | "NOT_READY"
  /** Request dropped because the sidecar was restarted (user cancel / kill SSH). */
  | "CANCELLED";

// ----------------------------------------------------------------------------
// Command catalogue. Grouped by source/family. Order matches the sidecar.
// ----------------------------------------------------------------------------
export type SidecarCommand =
  | "AddAria2Download"
  | "ApplyRuntimeConfig"
  | "CancelAria2DirectDownload"
  | "ClearInfraSshCredentialPassword"
  | "ClearLocalMachineCredentialPassword"
  | "ClearMacOsAdminCredentialCache"
  | "ClearPxeBootImagingLogs"
  | "ClearPxeBootLogTail"
  | "ControlAria2Download"
  | "DeleteInfraSshCredential"
  | "DownloadPxeBootFieldIso"
  | "DownloadPxeBootOptionalAsset"
  | "EnsureAria2Binary"
  | "EnsurePxeBootCaddy"
  | "EnsurePxeBootTftpd64"
  | "ExportPxeBootWimBootAssets"
  | "GetAria2Downloads"
  | "GetAria2PluginConfig"
  | "GetAria2TrackerCatalog"
  | "GetEvalIsoCatalog"
  | "GetLocalMachineCredential"
  | "GetTaskSequenceStepLibrary"
  | "GetTaskSequenceStepFromLibrary"
  | "GetPathFreeSpace"
  | "GetPxeBootFieldIsoStatus"
  | "GetPxeBootImagingClientLog"
  | "GetPxeBootImagingClients"
  | "GetPxeBootLogTail"
  | "GetPxeBootOptionalAssets"
  | "GetPxeBootPluginConfig"
  | "GetPxeBootPluginStatus"
  | "GetSecretVaultStatus"
  | "GetPxeBootTaskSequences"
  | "GetPxeBootWimLibrary"
  | "GetSidecarStatus"
  | "GetSiteProfile"
  | "ImportPxeBootIso"
  | "ImportPxeBootWim"
  | "ImportPxeBootWimBootAssets"
  | "ImportPxeBootWimFromIso"
  | "ListPxeBootIsos"
  | "ListPxeBootInstallImages"
  | "SetPxeBootBrandingImage"
  | "ClearPxeBootBrandingImage"
  | "GetPxeBootBrandingStatus"
  | "ListVaultSecrets"
  | "RemoveVaultSecret"
  | "SetVaultSecret"
  | "ListInfraSshCredentials"
  | "ListPxeBootIsoWims"
  | "LoadLocalMachineCredentialToSession"
  | "OpenAria2DownloadFolder"
  | "OpenPxeBootFieldIsoDriversFolder"
  | "OpenPxeBootIsoFolder"
  | "OpenPxeBootStoreFolder"
  | "OpenPxeBootWimFolder"
  | "Ping"
  | "PrefetchMacOsAdminCredential"
  | "PrepareAppExit"
  | "RefreshVendorSccmCatalogs"
  | "RemovePxeBootIso"
  | "RemovePxeBootWim"
  | "RevealSmbdForFullDiskAccess"
  | "RefreshEvalIsoCatalog"
  | "SavePxeBootTaskSequences"
  | "SetAria2PluginConfig"
  | "SetImageLibraryRoot"
  | "SetInfraSshCredential"
  | "SetLocalMachineCredential"
  | "SetPxeBootDefaultIso"
  | "SetPxeBootDefaultWim"
  | "SetPxeBootPluginConfig"
  | "SetSiteProfile"
  | "StartAria2Daemon"
  | "StartEvalIsoDownload"
  | "StartEvalIsoDownloadAll"
  | "StartPxeBootServices"
  | "StopAria2Daemon"
  | "StopPxeBootServices"
  | "SubmitAcerSccmCatalogHarvest"
  | "harvest_acer_sccm_urls";

// ----------------------------------------------------------------------------
// Bootstrap + session shapes
// ----------------------------------------------------------------------------
export type SessionState =
  | "connected"
  | "connecting"
  | "disconnected"
  | "error"
  | "skipped"
  | "unknown";

/** Deployment service readiness - the title-bar status dots. */
export interface SessionStatus {
  http: SessionState;
  tftp: SessionState;
  smb: SessionState;
  httpMessage?: string;
  tftpMessage?: string;
  smbMessage?: string;
}

export type InfrastructureProbeKind = "icmp" | "http" | "tcp";

export interface InfrastructureProbeResult {
  ip?: string;
  hostname?: string;
  url?: string;
  status: "up" | "flaky" | "down";
  replies: number;
  attempts: number;
  detail?: string;
  message?: string;
}

/** Field PXE boot plug-in - local TFTP + HTTP for onsite imaging. */
export interface PxeBootPluginConfig {
  httpPort: number;
  interfaceId?: string | null;
  deployMenuUrl: string;
  /** Primary ISO catalog: local laptop /ISOs or WAN deploy server */
  isoCatalogSource?: "local" | "wan";
  tftpd64Path?: string | null;
  tftpMode?: "router" | "standalone" | "proxy" | string;
  defaultBootWim?: string | null;
  /** When FieldIso.wim is default boot WIM - auto-boot this local ISO (else ISO catalog menu). */
  defaultBootIso?: string | null;
  /** DHCP Option 67 - path relative to tftp/ (e.g. snponly.efi or x86_64-sb/shimx64.efi). */
  tftpBootFile?: string | null;
  /** When true, PXE clients skip the menu and chain straight to defaultBootWim / defaultBootIso. */
  autoBootDefault?: boolean;
  /** When true, share the image library root as a hidden, read-only SMB share (Deploy$). */
  smbShareEnabled?: boolean;
  /** When true (and smbShareEnabled), the deploy UNC points at THIS machine's Deploy$. Off = on-site WDS UNC. */
  smbOverlayEnabled?: boolean;
  /** Overlay credentials: blank | throwaway | dept | vault:<infra-credential-id> */
  deployOverlayCreds?: string;
  /** Share name used in the overlaid Deploy UNC (\\<this-machine>\<share>). Default Deploy$. */
  deployOverlayShare?: string;
  /** When true, mount library ISOs read-only and serve sources/install.wim in place (no extraction). */
  isoMountServe?: boolean;
  updatedAt?: string | null;
}

export interface PxeBootIsoMountEntry {
  isoFileName: string;
  base: string;
  displayName?: string | null;
  installWim?: string | null;
  httpPath: string;
}

export interface PxeBootIsoMountStatus {
  enabled: boolean;
  mounts: PxeBootIsoMountEntry[];
}

export interface PxeBootSmbShareStatus {
  enabled: boolean;
  shareName: string;
  path?: string | null;
  unc?: string | null;
  readOnly: boolean;
  platform: "windows" | "macos" | "linux" | string;
  active: boolean;
  /** Throwaway SMB account WinPE authenticates with (WORKGROUP\<user>). */
  authUser?: string | null;
  authDomain?: string | null;
  /** macOS: root is under a TCC-protected folder (Downloads/Desktop/Documents) so smbd can't serve it. */
  tccBlocked?: boolean;
  guidance?: string | null;
  error?: string | null;
}

export interface PxeBootTftpBootFileEntry {
  fileName: string;
  sizeBytes: number;
  secureBoot?: boolean;
  /** True when this file is a Microsoft-shim entry point (valid Secure Boot Option 67). */
  secureBootShim?: boolean;
  recommended?: string | null;
  missing?: boolean;
  /** Friendly picker label for default presets (Option 67 dropdown). Includes file path + preset hint. */
  displayLabel?: string | null;
  preset?: boolean;
}

export interface PxeBootWimEntry {
  fileName: string;
  sizeBytes: number;
  modifiedAt?: string;
  isDefault: boolean;
  httpPath: string;
}

export interface PxeBootIsoEntry {
  fileName: string;
  sizeBytes: number;
  modifiedAt?: string;
  httpPath: string;
  isoUrlRel: string;
  label?: string;
  isDefault?: boolean;
}

export interface PxeBootFieldIsoStatus {
  present: boolean;
  fileName?: string | null;
  sizeBytes?: number | null;
  sha256?: string | null;
  expectedSize?: number;
  expectedSha256?: string | null;
  wimUrl: string;
  manifestUrl: string;
  manifestSource?: string;
  label?: string;
}

export interface PxeBootOptionalAssetStatus {
  id: string;
  kind: "wim" | "iso";
  label: string;
  fileName: string;
  present: boolean;
  sizeBytes?: number | null;
  expectedSize?: number;
  expectedSha256?: string | null;
  downloadUrl: string;
}

export interface PxeBootOptionalAssetsStatus {
  manifestUrl?: string;
  manifestSource?: string;
  updated?: string | null;
  assets: PxeBootOptionalAssetStatus[];
}

export interface PxeBootCaddyStatus {
  ready: boolean;
  path?: string | null;
  installedVersion?: string | null;
  pinnedVersion?: string;
  needsInstall?: boolean;
}

export interface PxeBootFieldIsoDriversSummary {
  osRoot?: string;
  indexPath?: string;
  modelCount?: number;
  readyCount?: number;
  defaultReady?: boolean;
  generated?: string;
  httpPath?: string;
}

export interface PxeBootLayoutStatus {
  ok: boolean;
  storeRoot: string;
  tftpRoot: string;
  httpRoot: string;
  snponlyEfi: string;
  wimbootPath: string;
  wimFiles: string[];
  isoFiles?: string[];
  defaultBootWim?: string | null;
  defaultBootIso?: string | null;
  wims?: PxeBootWimEntry[];
  isos?: PxeBootIsoEntry[];
  fieldIsoWim?: string | null;
  isoCatalogSource?: "local" | "wan";
  localIsoCatalogUrl?: string | null;
  wanIsoCatalogUrl?: string | null;
  isoCatalogReady?: boolean;
  fieldIsoDrivers?: PxeBootFieldIsoDriversSummary;
  missing: string[];
  warnings: string[];
}

export interface PxeBootNetworkAdapter {
  id: string;
  name: string;
  description: string;
  ipv4: string[];
  isDefault?: boolean;
}

export interface PxeBootRouterInstructions {
  option66: string;
  option67: string;
  option66Label?: string;
  option67Label?: string;
  notes: string[];
}

export interface PxeBootPluginStatus {
  platform: string;
  storeRoot: string;
  layout: PxeBootLayoutStatus;
  config: PxeBootPluginConfig;
  adapters: PxeBootNetworkAdapter[];
  lanIp?: string | null;
  /** Set when lanIp is missing - explains VPN-only, unplugged Ethernet, etc. */
  lanIpHint?: string | null;
  httpRunning: boolean;
  httpPid?: number | null;
  httpUrl?: string | null;
  httpPort: number;
  tftpRunning: boolean;
  tftpPid?: number | null;
  tftpBackend?: string | null;
  running: boolean;
  /** Devices that pushed imaging logs within the last 3 minutes. */
  imagingClientsActive?: number;
  startedAt?: string | null;
  deployMenuUrl: string;
  isoCatalogSource?: "local" | "wan";
  localIsoCatalogUrl?: string | null;
  wanIsoCatalogUrl?: string | null;
  localIsoCatalogReady?: boolean;
  router: PxeBootRouterInstructions;
  bundledSnponly: boolean;
  bundledWimboot?: boolean;
  bundledSecureBoot?: boolean;
  dnsmasqPath?: string | null;
  tftpd64Path?: string | null;
  defaultBootWim?: string | null;
  defaultBootWimUrl?: string | null;
  defaultBootIso?: string | null;
  /** wimboot:<boot.wim> | fieldiso-catalog | fieldiso-iso:... | deploy-iso */
  bootChainMode?: string | null;
  /** e.g. " index=1 gui" for default WIM local wimboot line */
  defaultWimbootKernelOptions?: string | null;
  defaultWimbootUsesBootAssets?: boolean;
  wims?: PxeBootWimEntry[];
  isos?: PxeBootIsoEntry[];
  fieldIsoWim?: string | null;
  fieldIso?: PxeBootFieldIsoStatus;
  optionalAssets?: PxeBootOptionalAssetsStatus;
  httpLastError?: string | null;
  tftpLastError?: string | null;
  tftpElevatedCommand?: string | null;
  /** macOS: multiline sudo kill -9 / pkill when UDP/69 is blocked by a leftover dnsmasq */
  tftpPort69KillCommand?: string | null;
  /** Shell kill commands when TCP/httpPort is blocked by a leftover Caddy process */
  httpPortKillCommand?: string | null;
  httpBackend?: "caddy" | null;
  caddy?: PxeBootCaddyStatus;
  tftpElevated?: boolean;
  dnsmasqConfPath?: string | null;
  /** macOS: in-memory admin password cached for sudo (cleared on logout) */
  macOsAdminCredentialCached?: boolean;
  /** Saved local-machine administrator vault (this device, not site-scoped) */
  localMachineCredentialConfigured?: boolean;
  /** Configured DHCP Option 67 boot file (relative to tftp/). */
  tftpBootFile?: string | null;
  /** .efi files discovered under tftp/ for the Option 67 picker. */
  tftpBootFiles?: PxeBootTftpBootFileEntry[];
}

export interface PxeBootWimLibraryResponse {
  wims: PxeBootWimEntry[];
  isos?: PxeBootIsoEntry[];
  fieldIsoWim?: string | null;
  config: PxeBootPluginConfig;
  layout: PxeBootLayoutStatus;
  status?: PxeBootPluginStatus | null;
}

export interface ImportPxeBootWimResult {
  fileName: string;
  sizeBytes: number;
  /** True when BCD/boot.sdi/bootmgr were prepared automatically (or not required). */
  bootAssetsReady?: boolean;
  bootAssetsPackaged?: string[];
  bootAssetsExtracted?: string[];
  library: PxeBootWimLibraryResponse;
}

/** A *.wim file discovered inside an ISO (e.g. sources/boot.wim, sources/install.wim). */
export interface PxeBootIsoWimEntry {
  /** Opaque path used to extract the member (raw separators as listed by the host tool). */
  path: string;
  /** Forward-slash normalised path for display. */
  displayPath: string;
  name: string;
  sizeBytes: number;
}

export interface ListPxeBootIsoWimsResult {
  isoFileName: string;
  entries: PxeBootIsoWimEntry[];
}

export interface PxeBootPluginConfigResponse {
  config: PxeBootPluginConfig;
  layout: PxeBootLayoutStatus;
  status: PxeBootPluginStatus;
  smbShare?: PxeBootSmbShareStatus;
  isoMount?: PxeBootIsoMountStatus;
}

export interface PxeBootLogTailResponse {
  /** True when the dnsmasq/TFTP log file exists on disk. */
  available: boolean;
  /** Absolute path of the log file that was read. */
  path: string;
  /** Most-recent log lines (oldest first), tftp-root path shortened to the boot file name. */
  lines: string[];
  /** True when older lines were dropped to fit the line cap. */
  truncated: boolean;
}

/** Per-vendor result of a USM-side SCCM catalog refresh (replaces the retired CI job). */
export interface VendorSccmCatalogRefreshResult {
  vendor: string;
  ok: boolean;
  count: number;
  /** CI-era minimum-count guard rail for this vendor. */
  floor: number;
  /** Refreshed but suspiciously small - source may have broken. */
  belowFloor: boolean;
  fetchedAt?: string;
  error?: string | null;
  /** Acer only: structured models parsed from AcerCatalog.xml this refresh. */
  xmlModelCount?: number;
  /** Acer only: days since the last full KB browser harvest (null = never). */
  harvestAgeDays?: number | null;
}

export interface VendorSccmCatalogRefreshResponse {
  results: VendorSccmCatalogRefreshResult[];
  /** KB page the hidden webview harvests for Acer (a real browser passes the bot wall). */
  acerHarvestUrl?: string;
  /** Acer XML refresh failed or the last full KB harvest is missing/older than 60 days. */
  acerHarvestRecommended?: boolean;
  /** Started by the sidecar's two-week check, not the technician: reload quietly. */
  automatic?: boolean;
}

export interface AcerSccmCatalogHarvestResponse {
  ok: boolean;
  urlCount: number;
  modelCount: number;
}

/** One device that has pushed imaging logs to this host. */
export interface PxeBootImagingClient {
  /** BIOS serial; devices with no serial report MAC-<address> instead. */
  serial: string;
  make: string;
  model: string;
  /** Client IP as seen by the host (Caddy X-Forwarded-For). */
  ip?: string;
  /** ISO-8601 UTC of the most recent log push. */
  lastSeen: string;
  ageSeconds: number;
  /** Pushed within the last 3 minutes. */
  active: boolean;
  lastLine: string;
  logBytes: number;
}

export interface PxeBootImagingClientsResponse {
  clients: PxeBootImagingClient[];
}

/** One ordered first-boot step (specialize RunSynchronous). */
export interface PxeBootTaskSequenceStep {
  /** UI-only stable identity for React list keys (not persisted - the sidecar's
   * step normaliser drops unknown fields on save). */
  _key?: string;
  /** pwshEncoded carries a whole script as one step (base64 into -EncodedCommand). */
  type: "reg" | "cmd" | "pwsh" | "pwshEncoded" | string;
  description: string;
  /** reg only */
  op?: "add" | "delete" | string;
  path?: string;
  name?: string;
  valueType?: string;
  data?: string;
  /** cmd / pwsh only */
  command?: string;
}

/** One Netboot task sequence - generates a first-boot unattend.xml on the share. */
/** A local account created at first boot, with an optional single auto-logon. */
export interface PxeBootTaskSequenceLocalAccount {
  /** none | manual | vault. Vault mode takes the user name AND password from the credential. */
  mode?: "none" | "manual" | "vault" | string;
  enabled: boolean;
  name: string;
  displayName?: string;
  description?: string;
  group?: "Administrators" | "Users" | string;
  passwordSource?: "vault" | "manual" | string;
  vaultSecret?: string;
  /** Stored base64 (obfuscation only). Never rendered back into the panel. */
  password?: string;
  /** Send a newly typed password here; the sidecar encodes it at rest. */
  passwordPlain?: string;
  autoLogon?: boolean;
}

/** One entry in the first-boot settings library. */
export interface TaskSequenceLibraryEntry {
  id: string;
  name: string;
  category: string;
  applies: "client" | "server" | "both" | string;
  risk: "safe" | "caution" | string;
  description: string;
  source: string;
  stepType: string;
  parameter?: {
    name: string;
    label: string;
    type: "text" | "choice" | string;
    default: string;
    choices?: string[];
  };
}

export interface TaskSequenceLibraryLists {
  version: number;
  categories: string[];
  client: TaskSequenceLibraryEntry[];
  server: TaskSequenceLibraryEntry[];
  counts: { client: number; server: number; total: number };
}

/** A secret in the shared vault - name and metadata only; values never leave the sidecar. */
export interface VaultSecretSummary {
  name: string;
  type: string;
  updatedAt?: string;
  createdBy?: string;
  note?: string;
}

export interface VaultSecretsResponse {
  vault?: { vault?: string; ready?: boolean; error?: string | null; secretCount?: number };
  secrets: VaultSecretSummary[];
  saved?: boolean;
  removed?: boolean;
}

export interface PxeBootTaskSequence {
  id: string;
  name: string;
  kind: "client" | "server" | string;
  enabled: boolean;
  /** Publish-time template fields; deploy-time tokens ({{SITE}}, {{SERIAL}}, creds) stay literal. */
  fields: Record<string, string>;
  /** Domain groups added as local Administrators (domain joins only). */
  adminGroups?: string[];
  /** Ordered, editable first-boot steps. */
  steps?: PxeBootTaskSequenceStep[];
  /** Local account created at first boot (optional). */
  localAccount?: PxeBootTaskSequenceLocalAccount;
  /** Which install.wim (and index) this sequence deploys; absent = tech picks at the device. */
  image?: PxeBootTaskSequenceImage;
}

/** One image inside an install.wim, as wimlib reports it. */
export interface PxeBootInstallImage {
  index: number;
  name: string;
  description?: string;
  /** Edition ID, e.g. ServerStandardEval / Professional. */
  edition?: string;
  installType?: string;
  arch?: string;
  build?: string;
  /** Uncompressed size of the applied image. */
  sizeBytes?: number;
}

/** One selectable install image source on the deploy share (an ISO, or a WIM in WIMs/). */
export interface PxeBootInstallImageEntry {
  /** 'iso:<file>' or 'wim:<file>' - what a task sequence stores. */
  id: string;
  kind: "iso" | "wim" | string;
  fileName: string;
  label: string;
  sizeBytes: number;
  /** Path under the deploy share root, e.g. .mounts\<token>\sources\install.wim */
  sharePath: string;
  /** Path under the HTTP root, e.g. iso-wim/<token>/install.wim */
  httpPath: string;
  /** False until the editions have been read once (reading mounts the ISO). */
  imagesKnown: boolean;
  images: PxeBootInstallImage[];
}

export interface PxeBootTaskSequenceImage {
  /** Matches PxeBootInstallImageEntry.id. */
  sourceId: string;
  index: number;
  /** Remembered so the panel can name the edition when the media is offline. */
  editionName?: string;
  /** Set by the sidecar on a published row when the source is gone. */
  missing?: boolean;
}

/** Boot WIM customisation: the WinPE background injected at boot (WIM untouched). */
export interface PxeBootBrandingStatus {
  winpeBackground: {
    present: boolean;
    fileName?: string | null;
    sizeBytes?: number;
    updatedAt?: string | null;
  };
}

export interface PxeBootTaskSequencesPayload {
  sequences: PxeBootTaskSequence[];
  /** Install image sources for the per-sequence image dropdown (cached editions only). */
  installImages?: PxeBootInstallImageEntry[];
  /** Locale/keyboard/timezone read from this host, used as Regional placeholders. */
  regionalDefaults?: { uiLanguage: string; inputLocale: string; timeZone: string };
  /** Absolute path of <library>/TaskSequences, null when no library root is set. */
  libraryDir?: string | null;
  publishedFiles: string[];
  /** Preselected imaging-client sequence id; '' = the None item (clean OOBE). */
  defaultSequenceId?: string;
  /** Credential-store entries offered for the join-credential selector. */
  credentialOptions?: { id: string; label: string; loginName?: string }[];
  /** Domains discovered from this host's DNS; verified = publishes the AD DC SRV record. */
  joinDomainSuggestions?: { domain: string; verified: boolean; source: string }[];
  /** Central domains + the site's local domain from the Site Profile. */
  joinDomainOptions?: string[];
  /** Site machine OUs from the Site Profile, labelled by first RDN. */
  machineOuOptions?: { dn: string; label: string }[];
  /** Reversed DN suggestion (CN=Computers,DC=...) for local-domain joins. */
  curricOuSuggestion?: string | null;
  /** GSV KMS client-setup key catalog (label = edition). */
  kmsKeyOptions?: { label: string; key: string }[];
  /** Role-default product keys (server-resolved - the frontend keeps no GVLK copy). */
  roleDefaults?: { client?: string; server?: string };
  /** Admin-group choices ({{SITE}} token form + corp groups). */
  adminGroupOptions?: string[];
}

export interface PxeBootImagingClientLogResponse {
  serial: string;
  available: boolean;
  /** Most-recent log lines (oldest first). */
  lines: string[];
}

export interface SetPxeBootPluginConfigParams {
  httpPort?: number;
  interfaceId?: string;
  deployMenuUrl?: string;
  isoCatalogSource?: "local" | "wan";
  tftpd64Path?: string;
  tftpMode?: string;
  tftpBootFile?: string;
  autoBootDefault?: boolean;
  smbShareEnabled?: boolean;
  smbOverlayEnabled?: boolean;
  deployOverlayCreds?: string;
  isoMountServe?: boolean;
  /** Skip boot.ipxe regen when only changing Option 67. */
  skipMenuRegen?: boolean;
}

export interface StartPxeBootServicesParams {
  httpOnly?: boolean;
  tftpOnly?: boolean;
}

export interface StopPxeBootServicesParams {
  httpOnly?: boolean;
  tftpOnly?: boolean;
}

/** aria2 torrent client plug-in (Plug-ins panel). */
export interface Aria2BinaryStatus {
  ready: boolean;
  path?: string | null;
  pinnedVersion?: string;
  installedVersion?: string | null;
  needsInstall?: boolean;
  installing?: boolean;
}

export interface Aria2ExtensionRoute {
  ext: string;
  assetKind: "iso" | "wim" | "driver" | "other" | string;
  usePxeStaging: boolean;
  dir?: string | null;
}

export interface Aria2PluginConfig {
  rpcPort: number;
  downloadDir?: string;
  storeRoot?: string;
  binary: Aria2BinaryStatus;
  daemonRunning: boolean;
  daemonPid?: number | null;
  pluginEnabled: boolean;
  pxeIntegrationEnabled?: boolean;
  pxeStoreAvailable?: boolean;
  pxeStoreRoot?: string | null;
  pxeStagingRoot?: string | null;
  extensionRoutes?: Aria2ExtensionRoute[];
}

export interface Aria2DownloadRow {
  gid: string;
  status: string;
  name?: string | null;
  totalLength: number;
  completedLength: number;
  downloadSpeed: number;
  percent: number;
  errorCode?: string | null;
  errorMessage?: string | null;
  assetKind?: string | null;
  promoteStatus?: string | null;
  promoteLabel?: string | null;
  promoteError?: string | null;
  /** Tracker catalog row id this transfer was started from (OS-image rows). */
  catalogRowId?: string | null;
}

export interface Aria2DownloadsPayload {
  daemonRunning: boolean;
  globalStat?: Record<string, string> | null;
  active: Aria2DownloadRow[];
  waiting: Aria2DownloadRow[];
  stopped: Aria2DownloadRow[];
}

export interface Aria2TrackerTorrentRow {
  id: string;
  name: string;
  assetKind: "iso" | "wim" | "driver" | "other" | string;
  catalogGroup?: "soe" | "oem" | string | null;
  torrentPath?: string | null;
  /** Size of the .torrent file itself - never show as the image size. */
  sizeBytes: number;
  /** Real payload size parsed from the torrent (0 when the manifest predates it). */
  contentSizeBytes?: number;
  downloadUrl?: string | null;
  subfolder?: string | null;
  source?: "sharepoint" | "bundled" | string;
  downloadable?: boolean;
  seeders?: number | null;
  leechers?: number | null;
  peerCountsAt?: string | null;
}

export interface Aria2TrackerOemIsoRow {
  id: string;
  name: string;
  assetKind: "iso" | string;
  uri?: string | null;
  torrentPath?: string | null;
  downloadUrl?: string | null;
  sizeBytes: number;
  subfolder?: string | null;
  source?: "sharepoint" | "bundled" | "manifest" | string;
  downloadable?: boolean;
  seeders?: number | null;
  leechers?: number | null;
  peerCountsAt?: string | null;
}

export interface Aria2TrackerDriverRow {
  kind: "driver";
  vendor: string;
  folder: string;
  modelName?: string | null;
  catalogFamily?: "thinkpad" | "yoga" | "11e" | "other" | string | null;
  catalogOnly?: boolean;
  expectedArchive?: string | null;
  /** Catalog-published pack hash (Dell/HP SHA-256, Acer MD5) - verified while streaming. */
  expectedHash?: string | null;
  expectedHashAlgorithm?: string | null;
  relPath?: string;
  aliases?: string[];
  nsspLabels?: string[];
  archiveReady?: boolean;
  uri?: string | null;
  magnet?: string | null;
  source?: "acer" | "lenovo" | "lenovo-support" | "dell" | "hp" | "manifest" | null;
  downloadable?: boolean;
}

/**
 * Microsoft Evaluation Center media. One row per downloadable edition (currently
 * en-US x64 ISO only); `id` is what StartEvalIsoDownload takes.
 */
export interface EvalIsoEntry {
  id: string;
  productId: string;
  productName: string;
  /** Product name as Microsoft writes it on the page, e.g. "Windows Server 2025 Preview". */
  title: string;
  edition: "Standard" | "LTSC" | string;
  media: "ISO" | "VHD" | string;
  arch: "x64" | "arm64" | "x86" | string;
  culture: string;
  /** The fwlink we download - stable; the file it redirects to is not. */
  url: string;
  resolvedUrl?: string;
  /** Real Microsoft file name, from the redirect chain; also how "downloaded" is matched. */
  fileName: string;
  sizeBytes: number;
  build?: string;
  release?: string;
  page: string;
  downloaded: boolean;
  localSizeBytes: number;
}

/** Per-product state, including releases that are retired or not published yet. */
export interface EvalIsoProduct {
  id: string;
  name: string;
  kind: "client" | "server" | string;
  probe?: boolean;
  page: string;
  /** ok = downloads offered; unavailable = page has none (retired); not-published = probe row waiting. */
  status?: "ok" | "unavailable" | "not-published" | "error" | string;
  message?: string;
  count?: number;
}

/** Media Microsoft only ships through the consumer page - link out, import by hand. */
export interface EvalIsoManualSource {
  id: string;
  name: string;
  url: string;
  reason: string;
}

export interface EvalIsoCatalogResponse {
  entries: EvalIsoEntry[];
  products: EvalIsoProduct[];
  manualSources: EvalIsoManualSource[];
  cached: boolean;
  fetchedAt: string;
  ageHours: number | null;
  ttlHours: number;
  stale: boolean;
  refreshing: boolean;
  isoDir: string;
}

export interface EvalIsoDownloadAllResponse {
  accepted: boolean;
  started: number;
  queued: number;
  totalBytes?: number;
  skipped?: number;
  message?: string;
}

export interface EvalIsoRefreshResponse {
  accepted: boolean;
  background?: boolean;
  alreadyRunning?: boolean;
  automatic?: boolean;
}

export interface Aria2TrackerCatalog {
  torrents: Aria2TrackerTorrentRow[];
  oemIsos: Aria2TrackerOemIsoRow[];
  drivers: Aria2TrackerDriverRow[];
  announceUrl?: string | null;
  statsUrl?: string | null;
  siteStatsUrl?: string | null;
  trackerUrl?: string | null;
  generatedAt?: string;
  acerCatalogAt?: string | null;
  acerCatalogStale?: boolean;
  acerCatalogSummary?: {
    travelmate?: number;
    total?: number;
    p2xx?: number;
    p4xx?: number;
    p6xx?: number;
    legacyP?: number;
    b1xx?: number;
    b3xx?: number;
    x3xx?: number;
    b514?: number;
    x514?: number;
    urlCount?: number;
  } | null;
  lenovoCatalogAt?: string | null;
  lenovoCatalogStale?: boolean;
  lenovoCatalogSummary?: {
    thinkpad?: number;
    yoga?: number;
    "11e"?: number;
    other?: number;
    total?: number;
  } | null;
  microsoftCatalogAt?: string | null;
  microsoftCatalogStale?: boolean;
  microsoftCatalogVersion?: string | null;
  microsoftCatalogSummary?: {
    "surface-pro"?: number;
    "surface-laptop"?: number;
    "surface-go"?: number;
    "surface-book"?: number;
    "surface-studio"?: number;
    other?: number;
    total?: number;
  } | null;
  dellCatalogAt?: string | null;
  dellCatalogStale?: boolean;
  dellCatalogSummary?: {
    latitude?: number;
    optiplex?: number;
    xps?: number;
    precision?: number;
    inspiron?: number;
    vostro?: number;
    other?: number;
    total?: number;
  } | null;
  hpCatalogAt?: string | null;
  hpCatalogStale?: boolean;
  hpCatalogOsColumn?: string | null;
  hpCatalogSummary?: {
    notebooks?: number;
    desktops?: number;
    workstations?: number;
    "thin-clients"?: number;
    other?: number;
    total?: number;
  } | null;
  note?: string;
}

export interface InfraSshCredentialSummary {
  id: string;
  label: string;
  /** SSH / RDP / web login (e.g. SITE01-admin, WORKGROUP\\localadmin). */
  loginName?: string;
  updatedAt?: string;
  configured: boolean;
  isDefault?: boolean;
  siteId?: string;
  /** App-provided virtual entry (e.g. app-de-signin, the signed-in DE account) -
   * site-agnostic, always offered, not editable/deletable in the manager. */
  builtIn?: boolean;
}

export interface ListInfraSshCredentialsResult {
  credentials: InfraSshCredentialSummary[];
  storePath: string;
}

export interface LocalMachineCredentialStatus {
  id: string;
  label: string;
  loginName?: string;
  configured: boolean;
  storePath: string;
  updatedAt?: string | null;
  platform?: string | null;
  sessionCached?: boolean;
  wiredForMacOs?: boolean;
  wiredForWindows?: boolean;
}

export interface ApplyRuntimeConfigParams {
  /** Settings -> Diagnostics -> Debug - bootstrap/IPC timing logs. */
  verboseLogging?: boolean;
  /** Settings -> Diagnostics -> Verbose PowerShell - native pwsh verbose/debug streams. */
  verbosePowershell?: boolean;
  /** Skip TLS cert validation for outbound HTTP (default true on macOS). */
  skipHttpCertificateCheck?: boolean;
  /** Node gates: nodeId -> enabled. Sent in full on every push (pxe-boot, aria2). */
  enabledPlugins?: Record<string, boolean>;
}
