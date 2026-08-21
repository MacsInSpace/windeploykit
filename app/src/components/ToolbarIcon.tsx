import type { ReactNode } from "react";

/**
 * MMC toolbar glyphs. Stroke-only, 16px, currentColor, so they inherit the
 * enabled/disabled state from the button - the toolbar is chrome and chrome
 * carries no palette of its own. Same set and drawing as PSOpenAD-FE.
 */
export type ToolbarGlyph = "back" | "forward" | "up" | "refresh" | "properties";

const PATHS: Record<ToolbarGlyph, ReactNode> = {
  back: <path d="M10 3.5 5.5 8l4.5 4.5" />,
  forward: <path d="M6 3.5 10.5 8 6 12.5" />,
  up: <path d="M8 12.5V4M4.5 7.5 8 4l3.5 3.5" />,
  refresh: (
    <>
      <path d="M13 8a5 5 0 1 1-1.6-3.7" />
      <path d="M13.4 2.6v2.6h-2.6" />
    </>
  ),
  properties: (
    <>
      <rect x="2.5" y="2" width="11" height="12" rx="1" />
      <path d="M5 5.5h6M5 8h6M5 10.5h3.5" />
    </>
  ),
};

export function ToolbarIcon({ glyph, size = 16 }: { glyph: ToolbarGlyph; size?: number }) {
  return (
    <svg
      className="tb-icon"
      viewBox="0 0 16 16"
      width={size}
      height={size}
      fill="none"
      stroke="currentColor"
      strokeWidth="1.4"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      {PATHS[glyph]}
    </svg>
  );
}
