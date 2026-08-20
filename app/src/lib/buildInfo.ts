/** Injected at package time via VITE_* env (see scripts/package-macos.sh). */
const version = import.meta.env.VITE_APP_VERSION ?? "dev";
const build = import.meta.env.VITE_BUILD_NUMBER ?? "dev";
const buildStamp = import.meta.env.VITE_BUILD_STAMP ?? "dev";
const variant = import.meta.env.VITE_APP_VARIANT ?? "dev";

/** Semver from package/tauri.conf at build time. */
export const APP_VERSION = version;

/** YYYYMMDD build stamp — logged in Sidecar host line and title bar. */
export const BUILD_STAMP = buildStamp;

/** Installer CPU variant: x64 | arm64 | aarch64 | x86_64 | universal | dev. */
export const APP_VARIANT = variant;

/** Shown in the title bar so packaged builds are identifiable after rebuild. */
export const BUILD_LABEL = `${version} · ${build}`;
