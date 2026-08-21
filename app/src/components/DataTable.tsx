import type { ReactNode } from "react";

import type { SortDirection } from "../lib/tableSort";

export interface DataTableColumn<R> {
  key: string;
  label: string;
  width?: number | string;
  render?: (row: R) => ReactNode;
  /** Default true - render as monospace (data). Set false for sans columns. */
  mono?: boolean;
  /** When `onSortColumn` is set, column is sortable unless explicitly false. */
  sortable?: boolean;
  /** Value used for alphanumeric / numeric column sort (recommended when `render` is set). */
  sortValue?: (row: R) => string | number | null | undefined;
}

interface DataTableProps<R> {
  columns: DataTableColumn<R>[];
  rows: R[];
  loading?: boolean;
  selectedId?: string | null;
  rowKey: (row: R) => string;
  onRowClick?: (row: R) => void;
  rowActions?: (row: R) => ReactNode;
  emptyMessage?: string;
  /** Full-width spacer row (e.g. between grouped sections). */
  isSeparatorRow?: (row: R) => boolean;
  /**
   * Opt-in multi-select. When true a checkbox column is rendered as the
   * first column with a header "select-all" that toggles every row
   * currently in `rows` (i.e. respects the active filter). The parent
   * owns the set of selected keys so it can layer in cross-page or
   * cross-filter persistence if needed.
   */
  selectable?: boolean;
  selectedKeys?: ReadonlySet<string>;
  onSelectionChange?: (next: Set<string>) => void;
  /** Active sort column key (controlled by parent). */
  sortKey?: string | null;
  sortDir?: SortDirection;
  onSortColumn?: (key: string) => void;
  /** Extra class names per row (e.g. pending removal styling). */
  rowClassName?: (row: R) => string | undefined;
  /** When true the row is non-interactive (no select, actions, or row click). */
  isRowDisabled?: (row: R) => boolean;
}

export function DataTable<R>(props: DataTableProps<R>) {
  const {
    columns,
    rows,
    loading,
    selectedId,
    rowKey,
    onRowClick,
    rowActions,
    emptyMessage = "No data",
    isSeparatorRow,
    selectable,
    selectedKeys,
    onSelectionChange,
    sortKey,
    sortDir = "asc",
    onSortColumn,
    rowClassName,
    isRowDisabled,
  } = props;

  const visibleKeys = rows.map(rowKey);
  const selectedCount = selectable && selectedKeys
    ? visibleKeys.filter((k) => selectedKeys.has(k)).length
    : 0;
  const allVisibleSelected = selectable && rows.length > 0 && selectedCount === rows.length;
  const someVisibleSelected = selectable && selectedCount > 0 && selectedCount < rows.length;

  const toggleOne = (key: string) => {
    if (!selectable || !onSelectionChange) return;
    const next = new Set(selectedKeys ?? []);
    if (next.has(key)) next.delete(key); else next.add(key);
    onSelectionChange(next);
  };

  const toggleAll = () => {
    if (!selectable || !onSelectionChange) return;
    const next = new Set(selectedKeys ?? []);
    if (allVisibleSelected) {
      for (const k of visibleKeys) next.delete(k);
    } else {
      for (const k of visibleKeys) next.add(k);
    }
    onSelectionChange(next);
  };

  return (
    <div
      className="data-table-frame overflow-auto"
      style={{ background: "var(--surface)", border: "1px solid var(--border)" }}
    >
      <table className="dk-table">
        <thead>
          <tr>
            {selectable && (
              <th style={{ width: 32 }}>
                <input
                  type="checkbox"
                  aria-label={allVisibleSelected ? "Clear selection" : "Select all visible"}
                  checked={allVisibleSelected}
                  ref={(el) => {
                    if (el) el.indeterminate = !!someVisibleSelected;
                  }}
                  onChange={toggleAll}
                  onClick={(e) => e.stopPropagation()}
                />
              </th>
            )}
            {columns.map((c) => {
              const canSort = !!onSortColumn && c.sortable !== false;
              const active = sortKey === c.key;
              return (
                <th
                  key={c.key}
                  style={{
                    width: c.width,
                    cursor: canSort ? "pointer" : undefined,
                    userSelect: canSort ? "none" : undefined,
                    color: active ? "var(--accent2)" : undefined,
                  }}
                  onClick={
                    canSort
                      ? (e) => {
                          e.stopPropagation();
                          onSortColumn(c.key);
                        }
                      : undefined
                  }
                  title={canSort ? "Sort column" : undefined}
                >
                  <span className="inline-flex items-center gap-1">
                    {c.label}
                    {active ? (
                      <span className="mono text-[9px]" style={{ color: "var(--accent)" }}>
                        {sortDir === "asc" ? "^" : "v"}
                      </span>
                    ) : null}
                  </span>
                </th>
              );
            })}
            {rowActions && <th style={{ width: 80 }} />}
          </tr>
        </thead>
        <tbody>
          {loading &&
            Array.from({ length: 5 }).map((_, i) => (
              <tr key={`skeleton-${i}`}>
                {selectable && <td />}
                {columns.map((c) => (
                  <td key={c.key}>
                    <div className="skeleton h-3 w-[80%] rounded-sm" />
                  </td>
                ))}
                {rowActions && <td />}
              </tr>
            ))}

          {!loading && rows.length === 0 && (
            <tr>
              <td colSpan={columns.length + (rowActions ? 1 : 0) + (selectable ? 1 : 0)}>
                <div
                  className="flex items-center justify-center py-8 text-[12px]"
                  style={{ color: "var(--text3)" }}
                >
                  {emptyMessage}
                </div>
              </td>
            </tr>
          )}

          {!loading &&
            rows.map((row) => {
              const id = rowKey(row);
              if (isSeparatorRow?.(row)) {
                const colSpan =
                  columns.length + (rowActions ? 1 : 0) + (selectable ? 1 : 0);
                const label =
                  typeof (row as Record<string, unknown>).DisplayName === "string"
                    ? String((row as Record<string, unknown>).DisplayName)
                    : typeof (row as Record<string, unknown>).Name === "string"
                      ? String((row as Record<string, unknown>).Name)
                      : "";
                return (
                  <tr key={id} className="dk-table-separator">
                    <td colSpan={colSpan} style={{ padding: "10px 8px 6px" }}>
                      {label ? (
                        <div
                          className="mono mb-1.5 text-[9px] uppercase"
                          style={{ color: "var(--text3)", letterSpacing: "0.1em" }}
                        >
                          {label}
                        </div>
                      ) : null}
                      <div
                        style={{
                          borderTop: "1px solid var(--border)",
                        }}
                      />
                    </td>
                  </tr>
                );
              }
              const disabled = isRowDisabled?.(row) ?? false;
              const isSelected = selectedId === id;
              const isChecked = selectable && !disabled && !!selectedKeys?.has(id);
              const extraClass = rowClassName?.(row);
              const trClass = [isSelected ? "selected" : "", extraClass].filter(Boolean).join(" ");
              return (
                <tr
                  key={id}
                  className={trClass || undefined}
                  onClick={() => onRowClick?.(row)}
                  style={disabled ? { cursor: "default" } : undefined}
                >
                  {selectable && (
                    <td onClick={(e) => e.stopPropagation()}>
                      <input
                        type="checkbox"
                        aria-label={`Select ${id}`}
                        checked={!!isChecked}
                        disabled={disabled}
                        onChange={() => toggleOne(id)}
                      />
                    </td>
                  )}
                  {columns.map((c) => (
                    <td key={c.key} className={c.mono === false ? "" : "mono"}>
                      {c.render
                        ? c.render(row)
                        : formatScalar((row as Record<string, unknown>)[c.key])}
                    </td>
                  ))}
                  {rowActions && (
                    <td className="text-right">
                      {disabled ? (
                        <span
                          className="mono text-[10px]"
                          style={{ color: "var(--text3)" }}
                          title="Removal pending - waiting for directory replication"
                        >
                          Removing...
                        </span>
                      ) : (
                        <span
                          className="row-actions"
                          onClick={(e) => e.stopPropagation()}
                        >
                          {rowActions(row)}
                        </span>
                      )}
                    </td>
                  )}
                </tr>
              );
            })}
        </tbody>
      </table>
    </div>
  );
}

function formatScalar(v: unknown): ReactNode {
  if (v === null || v === undefined || v === "") {
    return <span style={{ color: "var(--text3)" }}>-</span>;
  }
  if (Array.isArray(v)) {
    return `${v.length} item${v.length === 1 ? "" : "s"}`;
  }
  if (typeof v === "object") {
    return <span style={{ color: "var(--text3)" }}>{"{ ... }"}</span>;
  }
  return String(v);
}
