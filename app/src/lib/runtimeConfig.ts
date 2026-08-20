import { APP_VARIANT, APP_VERSION, BUILD_STAMP } from "./buildInfo";
import { getSetting } from "./settings";
import {
  SETTING_VERBOSE_LOGGING,
  SETTING_VERBOSE_POWERSHELL,
  SETTING_SKIP_HTTP_CERTIFICATE_CHECK,
} from "./runtimeSettings";
import type { ApplyRuntimeConfigParams } from "./types";

/** Environment handed to the sidecar process at spawn. */
export function buildSidecarSpawnEnv(): Record<string, string> {
  return {
    APP_VERBOSE_LOGGING: getSetting(SETTING_VERBOSE_LOGGING) ? "1" : "0",
    APP_VERBOSE_POWERSHELL: getSetting(SETTING_VERBOSE_POWERSHELL) ? "1" : "0",
    APP_VERSION,
    APP_BUILD: BUILD_STAMP,
    APP_VARIANT,
  };
}

/** Settings pushed to the sidecar via ApplyRuntimeConfig. */
export function buildRuntimeConfigForSidecar(): ApplyRuntimeConfigParams {
  return {
    verboseLogging: getSetting(SETTING_VERBOSE_LOGGING),
    verbosePowershell: getSetting(SETTING_VERBOSE_POWERSHELL),
    skipHttpCertificateCheck: getSetting(SETTING_SKIP_HTTP_CERTIFICATE_CHECK),
  };
}
