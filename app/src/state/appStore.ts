/**
 * Minimal app state for WinDeployKit.
 *
 * The upstream original was an 815-line store built around site context, directory
 * sessions and no sign-in. None of that applies here: WinDeployKit has no
 * directory session and no sign-in gate. What survives is the Site Profile —
 * the small set of site-wide values task sequences and the deploy share need.
 *
 * TODO(Site Profile): back this with the sidecar Site Profile store
 * (GetSiteProfile / SetSiteProfile) instead of the in-memory default.
 */
import { useSyncExternalStore } from "react";

export interface SiteProfile {
  /** Short site identifier used for the {{SITE}} naming token. */
  siteId: string | null;
  /** Default AD domain to join. */
  joinDomain: string | null;
  /** Host serving the deploy share when it is not this machine. */
  deployShareHost: string | null;
}

export interface AppState {
  siteProfile: SiteProfile;
}

const EMPTY_PROFILE: SiteProfile = {
  siteId: null,
  joinDomain: null,
  deployShareHost: null,
};

let state: AppState = { siteProfile: EMPTY_PROFILE };
const listeners = new Set<() => void>();

function emit(): void {
  for (const l of listeners) l();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function getAppState(): AppState {
  return state;
}

export function setSiteProfile(next: Partial<SiteProfile>): void {
  state = { ...state, siteProfile: { ...state.siteProfile, ...next } };
  emit();
}

export function useAppState(): AppState {
  return useSyncExternalStore(subscribe, getAppState, getAppState);
}

export function useSiteProfile(): SiteProfile {
  return useAppState().siteProfile;
}

/**
 * Site id used to key per-site caches.
 * @deprecated Kept for ported call sites — prefer `useSiteProfile()`.
 */
export function useSiteIdForQueries(): string | null {
  return useAppState().siteProfile.siteId;
}
