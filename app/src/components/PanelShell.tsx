import type { ReactNode } from "react";
import { AppIcon } from "./AppIcon";
import { InfoTip, type MaybeInfoTipRow } from "./InfoTip";

export interface PanelTab {
  id: string;
  label: string;
  count?: number | string;
}

interface PanelShellProps {
  /** Icon name for the header - usually the nav node id. */
  icon?: string;
  title: ReactNode;
  /**
   * ONE scannable fact - counts, or the current target. Keep it short enough to
   * never wrap; anything longer belongs in `details`. Style guide section "Help text
   * & tooltips": less is more.
   */
  subtitle?: ReactNode;
  /**
   * Supporting context (source host, cache age, filters, hints) shown on hover
   * of an info dot beside the subtitle. Values are live - they re-render while
   * the tip is open. Falsy entries are dropped, so inline conditionals are fine.
   */
  details?: MaybeInfoTipRow[];
  /** Right-anchored toolbar (search, filters, primary actions). */
  toolbar?: ReactNode;
  /**
   * Optional left-anchored toolbar slot, rendered immediately after the
   * title block. Use for contextual UI like a selection-action group
   * that shouldn't push the right-anchored toolbar around when it
   * appears / disappears.
   */
  toolbarLeft?: ReactNode;
  /** Optional tab bar (style guide section 4 "[Optional tab bar] (36px)"). */
  tabs?: PanelTab[];
  activeTabId?: string;
  onTabSelect?: (id: string) => void;
  /**
   * Body container classes. Default scrolls the whole panel body (`overflow-auto`).
   * Use `overflow-hidden` + an inner flex layout when a child region needs its own scroll.
   */
  bodyClassName?: string;
  children: ReactNode;
}

export function PanelShell({
  icon,
  title,
  subtitle,
  details,
  toolbar,
  toolbarLeft,
  tabs,
  activeTabId,
  onTabSelect,
  bodyClassName,
  children,
}: PanelShellProps) {
  return (
    <div className="panel-shell flex h-full min-h-0 flex-col">
      <div className="panel-header">
        {icon && (
          <div className="panel-heading-icon" aria-hidden="true">
            <AppIcon name={icon} size={16} />
          </div>
        )}
        <div className="panel-heading-copy min-w-0">
          <div className="panel-title truncate" style={{ color: "var(--text)" }}>
            {title}
          </div>
          {(subtitle || details?.some(Boolean)) && (
            <div className="panel-subtitle-row">
              {subtitle && (
                <span className="panel-subtitle mono truncate" style={{ color: "var(--text3)" }}>
                  {subtitle}
                </span>
              )}
              <InfoTip rows={details} label="Panel details" />
            </div>
          )}
        </div>
        {toolbarLeft && <div className="panel-toolbar-left">{toolbarLeft}</div>}
        <div className="panel-toolbar">{toolbar}</div>
      </div>
      {tabs && tabs.length > 0 && (
        <div className="panel-tabs" role="tablist" aria-label="Panel views">
          {tabs.map((t) => {
            const isActive = t.id === activeTabId;
            return (
              <button
                key={t.id}
                onClick={() => onTabSelect?.(t.id)}
                className={`panel-tab ${isActive ? "is-active" : ""}`}
                role="tab"
                aria-selected={isActive}
              >
                <span>{t.label}</span>
                {t.count != null && (
                  <span
                    className="mono text-[9.5px]"
                    style={{
                      color: isActive ? "var(--accent2)" : "var(--text3)",
                    }}
                  >
                    {t.count}
                  </span>
                )}
              </button>
            );
          })}
        </div>
      )}
      <div
        className={`panel-body min-h-0 flex-1 ${bodyClassName ?? "overflow-auto"}`}
      >
        {children}
      </div>
    </div>
  );
}
