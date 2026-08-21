/**
 * The console tree - the MDT Deployment Workbench left pane.
 *
 * Shaped like MMC's tree because that shape is how a technician orients in the
 * first second: the Deployment Share root with its nodes nested beneath, dotted
 * connector lines, a twist per expandable node, whole-row selection. Same row
 * anatomy and tokens as PSOpenAD-FE's ConsoleTree (26px rows, --sel-bg).
 *
 * Right-click selects the node and opens the same verbs the Action menu shows;
 * the shell owns that menu, so this component only reports the event.
 */
import type { MouseEvent } from "react";

import { AppIcon } from "./AppIcon";
import { NAV_TREE, type NavNode } from "./navConfig";

interface ConsoleTreeProps {
  activeId: string;
  collapsed: ReadonlySet<string>;
  onSelect: (id: string) => void;
  onToggle: (id: string) => void;
  onContextMenu: (e: MouseEvent, node: NavNode) => void;
  /** Node ids whose services are unavailable - rendered dimmed, still clickable. */
  disabledIds?: ReadonlySet<string>;
}

export function ConsoleTree(props: ConsoleTreeProps) {
  return (
    <div className="tree-scroll" role="tree" aria-label="Console tree">
      <ul className="tree-list is-root">
        {NAV_TREE.map((node) => (
          <TreeBranch key={node.id} node={node} {...props} />
        ))}
      </ul>
    </div>
  );
}

function TreeBranch({
  node,
  activeId,
  collapsed,
  onSelect,
  onToggle,
  onContextMenu,
  disabledIds,
}: ConsoleTreeProps & { node: NavNode }) {
  const hasChildren = Boolean(node.children?.length);
  const expanded = hasChildren && !collapsed.has(node.id);
  const selected = activeId === node.id;
  const dimmed = disabledIds?.has(node.id) ?? false;

  return (
    <li>
      <div
        className={[
          "tree-row",
          selected ? "is-selected" : "",
          node.root ? "is-root-node" : "",
          dimmed ? "is-dimmed" : "",
        ]
          .filter(Boolean)
          .join(" ")}
        role="treeitem"
        aria-selected={selected}
        aria-expanded={hasChildren ? expanded : undefined}
        onContextMenu={(e) => onContextMenu(e, node)}
      >
        {hasChildren ? (
          <button
            type="button"
            className={expanded ? "tree-twist is-open" : "tree-twist"}
            aria-label={expanded ? "Collapse" : "Expand"}
            onClick={(e) => {
              e.stopPropagation();
              onToggle(node.id);
            }}
          >
            &#9656;
          </button>
        ) : (
          <span className="tree-twist" aria-hidden />
        )}
        <button
          type="button"
          className="tree-node"
          title={dimmed ? `${node.label} - deployment services are not running` : node.label}
          onClick={() => onSelect(node.id)}
          /* MMC expands a node when you double-click its label. */
          onDoubleClick={() => hasChildren && onToggle(node.id)}
          onKeyDown={(e) => {
            if (e.key === "ArrowRight" && hasChildren && !expanded) onToggle(node.id);
            else if (e.key === "ArrowLeft" && hasChildren && expanded) onToggle(node.id);
          }}
        >
          <AppIcon name={node.icon} size={14} />
          <span className="tree-label">{node.label}</span>
          {node.badge !== undefined && (
            <span className={`tree-badge ${node.badgeVariant ?? ""}`}>{node.badge}</span>
          )}
        </button>
      </div>

      {hasChildren && expanded && (
        <ul className="tree-list" role="group">
          {node.children!.map((child) => (
            <TreeBranch
              key={child.id}
              node={child}
              activeId={activeId}
              collapsed={collapsed}
              onSelect={onSelect}
              onToggle={onToggle}
              onContextMenu={onContextMenu}
              disabledIds={disabledIds}
            />
          ))}
        </ul>
      )}
    </li>
  );
}
