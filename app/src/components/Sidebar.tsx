/**
 * Console tree — the MDT Deployment Workbench left pane.
 *
 * One vertical tree: a Deployment Share root with its nodes nested beneath,
 * each row a single line with a disclosure caret, icon and label. Selection is
 * a left accent rail, matching the style guide's `.nav-item.active`.
 */
import { useState } from "react";

import { AppIcon } from "./AppIcon";
import { NAV_TREE, type NavNode } from "./navConfig";

interface SidebarProps {
  activeId: string;
  onSelect: (id: string) => void;
  /** Node ids whose services are unavailable — rendered dimmed, still clickable. */
  disabledIds?: ReadonlySet<string>;
}

export function Sidebar({ activeId, onSelect, disabledIds }: SidebarProps) {
  // Everything starts expanded, like a freshly-opened Workbench.
  const [collapsed, setCollapsed] = useState<ReadonlySet<string>>(new Set());

  function toggle(id: string) {
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  return (
    <nav className="app-sidebar flex h-full min-h-0 flex-col border-r" aria-label="Console tree">
      <div className="product-lockup px-4 py-3">
        <div className="product-name">WinDeployKit</div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto py-1">
        <ul className="nav-tree" role="tree">
          {NAV_TREE.map((node) => (
            <TreeNode
              key={node.id}
              node={node}
              depth={0}
              activeId={activeId}
              collapsed={collapsed}
              disabledIds={disabledIds}
              onSelect={onSelect}
              onToggle={toggle}
            />
          ))}
        </ul>
      </div>
    </nav>
  );
}

interface TreeNodeProps {
  node: NavNode;
  depth: number;
  activeId: string;
  collapsed: ReadonlySet<string>;
  disabledIds?: ReadonlySet<string>;
  onSelect: (id: string) => void;
  onToggle: (id: string) => void;
}

function TreeNode({
  node,
  depth,
  activeId,
  collapsed,
  disabledIds,
  onSelect,
  onToggle,
}: TreeNodeProps) {
  const hasChildren = Boolean(node.children?.length);
  const isOpen = hasChildren && !collapsed.has(node.id);
  const isActive = activeId === node.id;
  const isDisabled = disabledIds?.has(node.id) ?? false;

  return (
    <li role="none">
      <div
        role="treeitem"
        tabIndex={0}
        aria-selected={isActive}
        aria-expanded={hasChildren ? isOpen : undefined}
        aria-level={depth + 1}
        title={isDisabled ? "Deployment services are not running" : node.label}
        className={[
          "nav-item",
          isActive ? "active" : "",
          node.root ? "nav-item-root" : "",
          isDisabled ? "nav-item-disabled" : "",
        ]
          .filter(Boolean)
          .join(" ")}
        // Indent one level per depth; the caret column keeps labels aligned.
        style={{ paddingLeft: `${8 + depth * 14}px` }}
        onClick={() => onSelect(node.id)}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            onSelect(node.id);
          } else if (e.key === "ArrowRight" && hasChildren && !isOpen) {
            onToggle(node.id);
          } else if (e.key === "ArrowLeft" && hasChildren && isOpen) {
            onToggle(node.id);
          }
        }}
      >
        <span
          className="nav-caret"
          aria-hidden="true"
          onClick={(e) => {
            if (!hasChildren) return;
            e.stopPropagation();
            onToggle(node.id);
          }}
        >
          {hasChildren ? (isOpen ? "▾" : "▸") : ""}
        </span>
        <AppIcon name={node.icon} size={14} />
        <span className="truncate">{node.label}</span>
        {node.badge !== undefined && (
          <span className={`nav-badge ${node.badgeVariant ?? ""}`}>{node.badge}</span>
        )}
      </div>

      {hasChildren && isOpen && (
        <ul role="group">
          {node.children!.map((child) => (
            <TreeNode
              key={child.id}
              node={child}
              depth={depth + 1}
              activeId={activeId}
              collapsed={collapsed}
              disabledIds={disabledIds}
              onSelect={onSelect}
              onToggle={onToggle}
            />
          ))}
        </ul>
      )}
    </li>
  );
}
