/**
 * In-memory query cache for sidecar invocations.
 *
 * Why this exists
 * ----------------
 * Some panels fetch genuinely heavy lists -- the bundled vendor driver
 * catalogs are ~1,500 rows. The default behaviour was "fetch on every
 * mount", so moving between nodes and back re-polled the same list every
 * time. This module caches results by key with a TTL so common navigation
 * stays instant.
 *
 * Note the house rule in docs/DATA_FRESHNESS.md: panels are LIVE by
 * default. Caching here is for a paint buffer (ttlMs: 0 + pollMs) or for
 * genuinely static remote data such as the vendor catalogs -- never for
 * machine state that can change without the app knowing.
 *
 * Design notes
 * ------------
 * - Memory-only. No localStorage / IndexedDB. Logging out
 *   wipes everything (see `invalidateAll`).
 * - Stale-while-revalidate: when a key is fetched while a stale
 *   entry exists, the stale `data` stays accessible to consumers
 *   until the fresh fetch resolves. UI shows the old list +
 *   a "refreshing" indicator instead of a flash of "Loading...".
 * - In-flight dedup: if two consumers ask for the same key at the
 *   same time, only one fetcher runs; both share the same promise.
 * - Pub/sub: useSyncExternalStore can hook into a per-key
 *   subscription list so re-renders are scoped tight.
 * - Hierarchical keys ('pxe:wims', 'drivers:lenovo:<model>') let
 *   `invalidatePrefix('drivers:')` nuke a whole namespace, e.g. after a
 *   catalog refresh.
 */

export type QueryStatus = "idle" | "pending" | "success" | "error";

/** Thrown by fetchers when a newer request superseded this one (do not update cache). */
export class StaleFetchError extends Error {
  constructor() {
    super("stale fetch");
    this.name = "StaleFetchError";
  }
}

export function isStaleFetchError(err: unknown): err is StaleFetchError {
  return err instanceof StaleFetchError || (err instanceof Error && err.name === "StaleFetchError");
}

export interface CacheEntry<T = unknown> {
  status: QueryStatus;
  data?: T;
  error?: string;
  /** ms timestamp of the last status transition. For 'success' this
   *  is the freshness anchor used by the TTL check. */
  fetchedAt: number;
  promise?: Promise<T>;
}

const cache = new Map<string, CacheEntry<unknown>>();
const perKeySubs = new Map<string, Set<() => void>>();

function notify(key: string): void {
  const subs = perKeySubs.get(key);
  if (!subs) return;
  // Snapshot before iterating so a sub that unsubscribes itself
  // mid-callback doesn't mutate the live set we're walking.
  for (const cb of Array.from(subs)) cb();
}

export function getCached<T>(key: string): CacheEntry<T> | undefined {
  return cache.get(key) as CacheEntry<T> | undefined;
}

export function setCached<T>(key: string, entry: CacheEntry<T>): void {
  cache.set(key, entry as CacheEntry<unknown>);
  notify(key);
}

export function subscribeKey(key: string, cb: () => void): () => void {
  let set = perKeySubs.get(key);
  if (!set) {
    set = new Set();
    perKeySubs.set(key, set);
  }
  set.add(cb);
  return () => {
    set!.delete(cb);
    if (set!.size === 0) perKeySubs.delete(key);
  };
}

export function invalidate(key: string): void {
  if (!cache.has(key)) return;
  cache.delete(key);
  notify(key);
}

/**
 * Mark a cache entry stale but keep `data` visible (stale-while-revalidate).
 * `useCachedQuery` / manual `fetchCached` will refetch without blanking the UI.
 */
export function revalidate(key: string): void {
  const entry = cache.get(key);
  if (!entry || entry.status === "pending") return;
  setCached(key, { ...entry, fetchedAt: 0 });
}

export function invalidatePrefix(prefix: string): void {
  const dropped: string[] = [];
  for (const k of cache.keys()) {
    if (k === prefix || k.startsWith(prefix + ":")) dropped.push(k);
  }
  for (const k of dropped) {
    cache.delete(k);
    notify(k);
  }
}

/** Soft-invalidate every key under a prefix - data stays on screen during refetch. */
export function revalidatePrefix(prefix: string): void {
  for (const [key, entry] of cache.entries()) {
    if (key !== prefix && !key.startsWith(prefix + ":")) continue;
    if (entry.status === "pending") continue;
    setCached(key, { ...entry, fetchedAt: 0 });
  }
}

export function invalidateAll(): void {
  const keys = Array.from(cache.keys());
  cache.clear();
  for (const k of keys) notify(k);
}

export function isFresh<T>(entry: CacheEntry<T> | undefined, ttlMs: number): boolean {
  if (!entry || entry.status !== "success") return false;
  return Date.now() - entry.fetchedAt < ttlMs;
}

/**
 * Resolve to a cached value when fresh; otherwise run `fetcher`,
 * memoise its promise (dedup), and update the cache.
 *
 * The returned promise rejects on fetch failure; the cache also
 * stores the error so subscribers can render it without re-running
 * the fetcher.
 */
export async function fetchCached<T>(
  key: string,
  fetcher: () => Promise<T>,
  ttlMs: number,
): Promise<T> {
  const existing = getCached<T>(key);
  if (isFresh(existing, ttlMs)) {
    return existing!.data as T;
  }
  if (existing?.status === "pending" && existing.promise) {
    return existing.promise as Promise<T>;
  }

  let resolveOuter!: (value: T) => void;
  let rejectOuter!: (err: unknown) => void;
  const promise = new Promise<T>((resolve, reject) => {
    resolveOuter = resolve;
    rejectOuter = reject;
  });

  // Mark pending but keep any stale data visible (stale-while-revalidate).
  setCached(key, {
    status: "pending",
    data: existing?.data,
    fetchedAt: Date.now(),
    promise,
  });

  fetcher().then(
    (data) => {
      setCached(key, { status: "success", data, fetchedAt: Date.now() });
      resolveOuter(data);
    },
    (err) => {
      if (isStaleFetchError(err)) {
        const keepStale =
          existing?.data !== undefined &&
          !(Array.isArray(existing.data) && existing.data.length === 0);
        if (keepStale) {
          const fetchedAt =
            existing.status === "success" ? existing.fetchedAt : Date.now();
          setCached(key, { status: "success", data: existing.data, fetchedAt });
          resolveOuter(existing.data as T);
        } else {
          cache.delete(key);
          notify(key);
          rejectOuter(err);
        }
        return;
      }
      const msg = err instanceof Error ? err.message : String(err);
      // Keep stale data on error so the UI doesn't blank out, but
      // surface the error so the panel can render a banner.
      setCached(key, {
        status: "error",
        data: existing?.data,
        error: msg,
        fetchedAt: Date.now(),
      });
      rejectOuter(err);
    },
  );

  return promise;
}

/** Debug helper -- safe to leave in; tree-shaken if unused. */
export function debugDumpCache(): Array<{ key: string; status: QueryStatus; ageMs: number; hasData: boolean }> {
  const now = Date.now();
  return Array.from(cache.entries()).map(([key, entry]) => ({
    key,
    status: entry.status,
    ageMs: now - entry.fetchedAt,
    hasData: entry.data !== undefined,
  }));
}
