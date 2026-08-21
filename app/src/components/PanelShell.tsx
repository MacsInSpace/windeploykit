/**
 * Result-pane frame: one 32px header line (title, then the one fact a
 * technician scans for, then the info dot), an optional flat tab row, and the
 * body. No toolbar - verbs belong to the console shell (state/consoleActions),
 * never to a panel header, so every node puts them in the same place.
 */
import type { ReactNode } from "react";

import { InfoTip, type MaybeInfoTipRow } from "./InfoTip";

export interface PanelTab {
  id: string;
  label: string;
  count?: number | string;
}

interface PanelShellProps {
  title: ReactNode;
  /** ONE scannable fact - a count, a path, the current target. Never wraps. */
  subtitle?: ReactNode;
  /** Supporting context behind the info dot. Values are live. */
  details?: MaybeInfoTipRow[];
  tabs?: PanelTab[];
  activeTabId?: string;
  onTabSelect?: (id: string) => void;
  /** Body container classes. Default scrolls the whole body. */
  bodyClassName?: string;
  children: ReactNode;
}

export function PanelShell({
  title,
  subtitle,
  details,
  tabs,
  activeTabId,
  onTabSelect,
  bodyClassName,
  children,
}: PanelShellProps) {
  return (
    <div className="panel-shell flex h-full min-h-0 flex-col">
      <div className="results-head">
        <span className="results-title">{title}</span>
        {subtitle && <span className="results-path">{subtitle}</span>}
        {details?.some(Boolean) && <InfoTip rows={details} label="Panel details" />}
      </div>
      {tabs && tabs.length > 0 && (
        <div className="panel-tabs" role="tablist" aria-label="Panel views">
          {tabs.map((t) => {
            const isActive = t.id === activeTabId;
            return (
              <button
                key={t.id}
                type="button"
                onClick={() => onTabSelect?.(t.id)}
                className={`panel-tab ${isActive ? "is-active" : ""}`}
                role="tab"
                aria-selected={isActive}
              >
                <span>{t.label}</span>
                {t.count != null && <span className="panel-tab-count mono">{t.count}</span>}
              </button>
            );
          })}
        </div>
      )}
      <div className={`panel-body min-h-0 flex-1 ${bodyClassName ?? "overflow-auto"}`}>{children}</div>
    </div>
  );
}
