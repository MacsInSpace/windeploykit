export type SortDirection = "asc" | "desc";

export function compareSortValues(
  a: string | number | null | undefined,
  b: string | number | null | undefined,
  dir: SortDirection,
): number {
  const isEmpty = (v: unknown) => v === null || v === undefined || v === "";
  if (isEmpty(a) && isEmpty(b)) return 0;
  if (isEmpty(a)) return 1;
  if (isEmpty(b)) return -1;

  const na = typeof a === "number" ? a : parseSortableNumber(String(a));
  const nb = typeof b === "number" ? b : parseSortableNumber(String(b));
  if (na !== null && nb !== null) {
    return dir === "asc" ? na - nb : nb - na;
  }

  const cmp = String(a).localeCompare(String(b), undefined, {
    numeric: true,
    sensitivity: "base",
  });
  return dir === "asc" ? cmp : -cmp;
}

function parseSortableNumber(s: string): number | null {
  const t = s.trim();
  if (!t || !/^-?\d+(\.\d+)?$/.test(t)) return null;
  const n = Number(t);
  return Number.isFinite(n) ? n : null;
}

export function nextSortDirection(
  currentKey: string | null,
  clickedKey: string,
  currentDir: SortDirection,
): SortDirection {
  return currentKey === clickedKey && currentDir === "asc" ? "desc" : "asc";
}
