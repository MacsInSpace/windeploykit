/**
 * React adapter for queryCache. Pattern is intentionally close to
 * react-query's `useQuery` so any team member who's seen that lib
 * can read it -- but we don't pull in the dependency (this app
 * uses zero React data-fetching libs by design).
 *
 * Pass a key (string) and a fetcher. The hook:
 *  - returns the cached entry's data immediately if fresh,
 *  - kicks off a background fetch otherwise,
 *  - re-renders on cache updates for this exact key,
 *  - exposes `refetch()` for the panel's manual Refresh button.
 *
 * `enabled` defers fetching until pre-conditions are met (e.g.,
 * siteId known). When disabled, the hook reads any cached
 * value but never triggers a fetch.
 */

import { useCallback, useEffect, useRef, useSyncExternalStore } from "react";

import {
  getCached,
  subscribeKey,
  fetchCached,
  invalidate as invalidateKey,
  isFresh,
  type CacheEntry,
  type QueryStatus,
} from "./queryCache";

export interface UseCachedQueryOptions {
  /** Time-to-live for the cached value. Defaults to 5 minutes. */
  ttlMs?: number;
  /** When false, the hook becomes read-only -- no fetches. */
  enabled?: boolean;
  /**
   * When false, refetch() keeps the previous data visible until the new fetch
   * completes (stale-while-revalidate). Use for live polling (e.g. the PXE log).
   */
  invalidateOnRefetch?: boolean;
  /**
   * Re-fetch every N ms while the hook is mounted. WinDeployKit panels show live
   * machine state (services up/down, transfers in flight, clients imaging), so
   * they poll rather than trusting a TTL - the cache only exists so a remount
   * paints instantly instead of flashing empty.
   */
  pollMs?: number;
}

export interface CachedQueryResult<T> {
  /** Cached value if any (may be stale during a refetch). */
  data: T | undefined;
  /** True while a fetch is in flight. With stale-while-revalidate,
   *  `data` may be defined at the same time. */
  loading: boolean;
  /** Last error message, if any. Cleared on the next successful fetch. */
  error: string | undefined;
  status: QueryStatus | "idle";
  /** Force a fresh fetch (invalidates the cache key first). */
  refetch: () => void;
}

const DEFAULT_TTL_MS = 5 * 60 * 1000;

/**
 * After a failed fetch, hold off automatic refetches for this long. Without a
 * cooldown the effect below re-runs on the error entry's own cache update
 * (deps include fetchedAt/status) and hot-loops the sidecar at render speed
 * whenever a command fails persistently. Manual refetch() bypasses this by
 * invalidating the key first.
 */
const ERROR_RETRY_COOLDOWN_MS = 30_000;

export function useCachedQuery<T>(
  key: string,
  fetcher: () => Promise<T>,
  opts: UseCachedQueryOptions = {},
): CachedQueryResult<T> {
  const {
    ttlMs = DEFAULT_TTL_MS,
    enabled = true,
    invalidateOnRefetch = true,
    pollMs,
  } = opts;

  const entry = useSyncExternalStore<CacheEntry<T> | undefined>(
    (cb) => subscribeKey(key, cb),
    () => getCached<T>(key),
    () => undefined,
  );

  // Keep fetcher in a ref. Panels often build the fetcher inline
  // (capturing `sidecar` etc) -- without the ref, the dep array
  // would churn and the effect would run on every render.
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;

  useEffect(() => {
    if (!enabled) return;
    const current = getCached<T>(key);
    if (isFresh(current, ttlMs)) return;
    if (current?.status === "pending") return;
    if (
      current?.status === "error" &&
      Date.now() - current.fetchedAt < ERROR_RETRY_COOLDOWN_MS
    ) {
      return;
    }
    void fetchCached(key, () => fetcherRef.current(), ttlMs).catch(() => {
      /* error is stored in the cache, subscribers will pick it up */
    });
  }, [key, enabled, ttlMs, entry?.fetchedAt, entry?.status]);

  // Live refresh while mounted. Bypasses the TTL deliberately - the cached
  // value is a paint buffer, not the source of truth, for anything that
  // reflects live machine state.
  useEffect(() => {
    if (!enabled || !pollMs || pollMs <= 0) return;
    const timer = window.setInterval(() => {
      void fetchCached(key, () => fetcherRef.current(), 0).catch(() => {});
    }, pollMs);
    return () => window.clearInterval(timer);
  }, [key, enabled, pollMs]);

  const refetch = useCallback(() => {
    if (invalidateOnRefetch) {
      invalidateKey(key);
    }
    if (enabled) {
      void fetchCached(key, () => fetcherRef.current(), ttlMs).catch(() => {});
    }
  }, [key, enabled, ttlMs, invalidateOnRefetch]);

  return {
    data: entry?.data,
    loading: entry?.status === "pending" || (entry === undefined && enabled),
    error: entry?.status === "error" ? entry.error : undefined,
    status: entry?.status ?? "idle",
    refetch,
  };
}
