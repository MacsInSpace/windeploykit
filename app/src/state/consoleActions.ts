/**
 * The one home for a node's verbs.
 *
 * Every panel used to render its own buttons in its own header, so the same
 * kind of action sat in a different place on every node. Now the mounted panel
 * publishes its verbs here and the console shell renders them in exactly three
 * uniform places, as the Workbench does: the Action menu, the right-click menu,
 * and the toolbar glyphs for the two verbs every node shares (Refresh,
 * Properties). Panels draw no action buttons of their own.
 */
import { useEffect, useId, useSyncExternalStore } from "react";
import type { MenuItem } from "../components/ContextMenu";

export interface ConsoleNodeActions {
  /** Verbs for the Action menu and the right-click menu, in Workbench order. */
  items: MenuItem[];
  /** Refresh - F5, the toolbar glyph, View > Refresh. */
  refresh?: () => void;
  /** Properties... - Alt+Enter, the toolbar glyph, File > Properties. */
  properties?: () => void;
  /** One fact for the status bar's left segment. */
  status?: string;
}

interface Registered extends ConsoleNodeActions {
  owner: string;
}

const EMPTY: ConsoleNodeActions = { items: [] };
let current: Registered | null = null;
const listeners = new Set<() => void>();

function emit() {
  for (const l of listeners) l();
}

function sameItems(a: MenuItem[], b: MenuItem[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    const x = a[i]!;
    const y = b[i]!;
    if (x.label !== y.label || Boolean(x.disabled) !== Boolean(y.disabled) || x.onSelect !== y.onSelect) {
      return false;
    }
  }
  return true;
}

export function publishConsoleActions(owner: string, def: ConsoleNodeActions): void {
  // Re-publishing an unchanged set must not notify: the shell re-renders on
  // notify, which re-renders the panel, which would publish again.
  if (
    current &&
    current.owner === owner &&
    current.refresh === def.refresh &&
    current.properties === def.properties &&
    current.status === def.status &&
    sameItems(current.items, def.items)
  ) {
    return;
  }
  current = { owner, ...def };
  emit();
}

export function clearConsoleActions(owner: string): void {
  // Only the owner clears. On a node switch the outgoing panel's cleanup can
  // run after the incoming panel's publish, and must not wipe it.
  if (current?.owner !== owner) return;
  current = null;
  emit();
}

export function subscribeConsoleActions(fn: () => void): () => void {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

export function getConsoleActions(): ConsoleNodeActions {
  return current ?? EMPTY;
}

/** Shell side: the active node's verbs, live. */
export function useConsoleActionsSnapshot(): ConsoleNodeActions {
  return useSyncExternalStore(subscribeConsoleActions, getConsoleActions, getConsoleActions);
}

/**
 * Panel side. `def` must be memoised by the caller (useMemo keyed on the state
 * the verbs depend on), otherwise every render republishes.
 */
export function useConsoleActions(def: ConsoleNodeActions): void {
  const owner = useId();
  useEffect(() => {
    publishConsoleActions(owner, def);
    return () => clearConsoleActions(owner);
  }, [owner, def]);
}
