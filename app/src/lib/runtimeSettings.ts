import { defineSetting } from "./settings";

const GROUP = "Network + Directory (advanced)";
const DEBUG_GROUP = "Diagnostics";











export const SETTING_VERBOSE_LOGGING = defineSetting({
  id: "diagnostics.verboseLogging",
  group: DEBUG_GROUP,
  label: "Debug",
  description:
    "Sidecar Log detail. ON: phase timings, IPC begin/complete (+Nms SLOW), HTTP routing, TLS policy, service start/stop steps. OFF: operational summaries and errors only. Default OFF; turn on when diagnosing. Applies immediately.",
  type: "boolean",
  defaultValue: false,
});

export const SETTING_VERBOSE_POWERSHELL = defineSetting({
  id: "diagnostics.verbosePowershell",
  group: DEBUG_GROUP,
  label: "Verbose PowerShell",
  description:
    "WARNING: VERY noisy - enables native pwsh Write-Verbose / Write-Debug output and cmdlet -Verbose detail in the Sidecar Log ([pwsh:verbose] / [pwsh:debug] prefixes). Use only when tracing third-party cmdlet behaviour. Default OFF. Toggling applies immediately.",
  type: "boolean",
  defaultValue: false,
});

/** pwsh on macOS rejects some private-CA HTTPS chains that browsers accept. */
export const SETTING_SKIP_HTTP_CERTIFICATE_CHECK = defineSetting({
  id: "network.skipHttpCertificateCheck",
  group: GROUP,
  label: "Skip HTTPS certificate validation",
  description:
    "When enabled, Invoke-RestMethod and Invoke-WebRequest skip TLS certificate checks - needed for an on-prem artifact server with a private CA. Turn off for strict validation.",
  type: "boolean",
  defaultValue: true,
});






