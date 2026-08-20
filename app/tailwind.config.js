/** @type {import('tailwindcss').Config} */
// Tokens mirror docs/WINDEPLOYKIT_App_StyleGuide.md §2-§7.
// If a token is added there, add it here. The style guide is the source of truth.
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        bg: "var(--bg)",
        surface: "var(--surface)",
        surface2: "var(--surface2)",
        surface3: "var(--surface3)",
        border: "var(--border)",
        border2: "var(--border2)",
        accent: "var(--accent)",
        accent2: "var(--accent2)",
        "accent-dim": "var(--accent-dim)",
        green: "var(--green)",
        "green-dim": "var(--green-dim)",
        amber: "var(--amber)",
        "amber-dim": "var(--amber-dim)",
        red: "var(--red)",
        "red-dim": "var(--red-dim)",
        purple: "var(--purple)",
        text1: "var(--text)",
        text2: "var(--text2)",
        text3: "var(--text3)",
      },
      fontFamily: {
        mono: ['"IBM Plex Mono"', '"JetBrains Mono"', '"Fira Code"', "monospace"],
        sans: ['"IBM Plex Sans"', "system-ui", "sans-serif"],
        cond: ['"IBM Plex Sans Condensed"', '"IBM Plex Sans"', "sans-serif"],
      },
      fontSize: {
        // Slightly denser scale than Tailwind defaults — matches the style guide.
        xxs: ["9px", "12px"],
        xs: ["10px", "14px"],
        sm: ["11px", "15px"],
        md: ["12px", "16px"],
        base: ["13px", "18px"],
      },
      letterSpacing: {
        wider2: "0.1em",
        widest2: "0.12em",
        widest3: "0.15em",
      },
      borderRadius: {
        none: "0px",
        sm: "2px",
        DEFAULT: "3px",
        md: "4px",
        lg: "5px",
        xl: "5px",
        "2xl": "5px",
        "3xl": "5px",
        full: "9999px",
      },
      transitionTimingFunction: {
        out12: "cubic-bezier(0.4, 0, 0.2, 1)",
      },
      transitionDuration: {
        120: "120ms",
        180: "180ms",
      },
      boxShadow: {
        "dot-ok": "0 0 4px #22c55e",
        "dot-err": "0 0 4px #ef4444",
        "dot-pending": "0 0 4px #f59e0b",
      },
    },
  },
  plugins: [],
};
