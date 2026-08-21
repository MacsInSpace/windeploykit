/**
 * Typed user-settings registry.
 *
 * Read order (first hit wins):
 *   1. localStorage override (set via the Settings overlay).
 *   2. Vite env var (build-time `.env.local`).
 *   3. Compiled-in default.
 *
 * Why all three layers? localStorage is the per-tech runtime knob
 * (the overlay writes here). Env still works for fleet-wide rollouts
 * via `.env.local`. Defaults guarantee the app always boots even
 * when both are absent or malformed.
 *
 * To add a setting:
 *   const MY_THING = defineSetting({
 *     id: "ttl.driverCatalogHours", // dotted, stable storage key
 *     group: "Cache TTLs (hours)",
 *     label: "Vendor driver catalogs",
 *     description: "How long...",
 *     type: "number",
 *     defaultValue: 168,
 *     unit: "h",                   // optional UI suffix
 *     min: 1, max: 24 * 30,        // optional clamp
 *     envVar: "VITE_TTL_DRIVER_CATALOG_HOURS", // optional env fallback
 *   });
 *   const ms = getSetting(MY_THING) * 3_600_000;
 *
 * Subscribe via `subscribeSettings(fn)` to react to overlay changes
 * mid-session (the overlay component does this). The Proxy returned
 * by getSetting always reads the latest -- existing in-flight cache
 * entries keep their original TTL because expiry is computed at
 * fetch time, but new fetches pick up the new value.
 */

export type SettingScalar = string | number | boolean;
export type SettingType = "number" | "string" | "boolean";

export interface SettingDef<T extends SettingScalar = SettingScalar> {
  /** Storage key. Dotted convention: "<area>.<thing>". Stable forever. */
  id: string;
  /** Human label rendered in the overlay. */
  label: string;
  /** Section heading in the overlay. */
  group: string;
  /** Longer help text shown under the input. */
  description?: string;
  /** Used to coerce raw localStorage strings + drive the UI input. */
  type: SettingType;
  /** Compiled-in default. Always returned by `getSetting` when no
   *  override and no env are set. */
  defaultValue: T;
  /** UI suffix ("min", "ms", "sec"...). Purely cosmetic. */
  unit?: string;
  /** Inclusive clamps for `type: "number"`. */
  min?: number;
  max?: number;
  /** Optional Vite env var name (must start with `VITE_`). */
  envVar?: string;
  /** True if changing this requires a full app restart to take
   *  effect (rare; flagged in the overlay so the user knows). */
  restartRequired?: boolean;
  /** Omit from Settings overlay (registry + runtime config unchanged). */
  hidden?: boolean;
}

const REGISTRY: SettingDef[] = [];

export function defineSetting<T extends SettingScalar>(def: SettingDef<T>): SettingDef<T> {
  // Reject duplicate IDs early -- typos are silent landmines later.
  if (REGISTRY.some((d) => d.id === def.id)) {
    throw new Error(`Duplicate setting id: ${def.id}`);
  }
  REGISTRY.push(def as SettingDef);
  return def;
}

export function listSettings(): readonly SettingDef[] {
  return REGISTRY;
}

export function listGroups(): string[] {
  const out: string[] = [];
  for (const d of REGISTRY) {
    if (d.hidden) continue;
    if (!out.includes(d.group)) out.push(d.group);
  }
  return out;
}

// ---------- storage layer ----------

const STORAGE_KEY = "windeploykit.settings.v1";

function readStore(): Record<string, SettingScalar> {
  if (typeof localStorage === "undefined") return {};
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === "object") return parsed as Record<string, SettingScalar>;
    return {};
  } catch {
    return {};
  }
}

function writeStore(s: Record<string, SettingScalar>) {
  if (typeof localStorage === "undefined") return;
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(s));
  } catch {
    // Quota / privacy modes are non-fatal; settings just become
    // session-local.
  }
}

// ---------- pub/sub ----------

type Listener = () => void;
const listeners = new Set<Listener>();

function notify(): void {
  for (const fn of listeners) {
    try {
      fn();
    } catch {
      // listener bugs shouldn't break other subscribers
    }
  }
}

export function subscribeSettings(fn: Listener): () => void {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

// Cross-tab/cross-window sync. Not strictly needed for Tauri's
// single webview, but cheap and useful in `vite dev` browser mode.
if (typeof window !== "undefined") {
  window.addEventListener("storage", (e) => {
    if (e.key === STORAGE_KEY) notify();
  });
}

// ---------- read / write helpers ----------

function coerce(type: SettingType, raw: unknown): SettingScalar | undefined {
  if (raw === undefined || raw === null || raw === "") return undefined;
  switch (type) {
    case "number": {
      const n = Number(raw);
      return Number.isFinite(n) ? n : undefined;
    }
    case "boolean": {
      if (typeof raw === "boolean") return raw;
      const s = String(raw).toLowerCase().trim();
      if (["1", "true", "yes", "on"].includes(s)) return true;
      if (["0", "false", "no", "off"].includes(s)) return false;
      return undefined;
    }
    case "string":
    default:
      return String(raw);
  }
}

function clampNumber(def: SettingDef, n: number): number {
  let v = n;
  if (typeof def.min === "number") v = Math.max(def.min, v);
  if (typeof def.max === "number") v = Math.min(def.max, v);
  return v;
}

function readEnv(def: SettingDef): SettingScalar | undefined {
  if (!def.envVar) return undefined;
  const env = (import.meta.env as Record<string, string | undefined>)[def.envVar];
  return coerce(def.type, env);
}

export function getSetting<T extends SettingScalar>(def: SettingDef<T>): T {
  const store = readStore();
  const override = coerce(def.type, store[def.id]);
  const candidate = override ?? readEnv(def) ?? def.defaultValue;
  if (def.type === "number") {
    return clampNumber(def, candidate as number) as T;
  }
  return candidate as T;
}

/** Returns whichever source the value came from. Used by the overlay
 *  to show "default" / "env" / "override" badges. */
export function getSettingSource(def: SettingDef): "override" | "env" | "default" {
  const store = readStore();
  if (coerce(def.type, store[def.id]) !== undefined) return "override";
  if (readEnv(def) !== undefined) return "env";
  return "default";
}

export function setSetting<T extends SettingScalar>(def: SettingDef<T>, v: T | null): void {
  const store = readStore();
  // Treat "set to default" as clear -- keeps localStorage minimal
  // and means the user sees "default" in the source badge afterward.
  if (v === null || v === undefined || v === def.defaultValue) {
    if (!(def.id in store)) return;
    delete store[def.id];
  } else {
    const coerced = coerce(def.type, v);
    if (coerced === undefined) return;
    store[def.id] = def.type === "number" ? clampNumber(def, coerced as number) : coerced;
  }
  writeStore(store);
  notify();
}

export function resetAllSettings(): void {
  writeStore({});
  notify();
}

/**
 * Notify settings subscribers of an external change that alters derived
 * values without touching `windeploykit.settings.v1` - device-local overrides
 * and active-site switches (lib/pluginSiteOverrides.ts). Everything that
 * re-reads plug-in enablement (sidebar nav, router, App effects) already
 * listens via `subscribeSettings`, so those changes reuse the same channel.
 */
export function emitSettingsChanged(): void {
  notify();
}

/** Cheap snapshot for debugging from the devtools console. */
export function debugDumpSettings(): Record<string, { current: SettingScalar; source: string }> {
  const out: Record<string, { current: SettingScalar; source: string }> = {};
  for (const def of REGISTRY) {
    out[def.id] = { current: getSetting(def), source: getSettingSource(def) };
  }
  return out;
}
