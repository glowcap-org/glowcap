/**
 * Visibility helpers — pure functions over `TimelineDocument`'s
 * `rowHidden` / `rowLabelHidden` / `rowBodyHidden` / `categoryVisMode`
 * / `allVisMode` fields. Extracted from `engine.ts` so the cascade
 * logic lives in one cohesive module instead of being threaded
 * through 130 lines of Engine class.
 *
 * The Engine class re-exposes these via thin wrappers
 * (`setRowVisMode` etc.) that add the post-mutation `#notify()`
 * call — same public surface as before. UI code that needs to read
 * (Stage, Timeline, Sidebar) should call `engine.effectiveRowVisMode`
 * or `engine.rowVisMode` and never reach for the doc fields
 * directly; the next phase's cascade-bug fix replaces only the
 * `effectiveRowVisMode` definition below, with no API churn.
 */

import type { TimelineDocument } from "./timeline.ts";

export type VisMode = "visible" | "label" | "body" | "both";
export type VisCategory = "peers" | "sessions" | "messages";

type RowHiddenLike = TimelineDocument["rowHidden"];

/** Drop `id` from `field[category]`; collapse the array (and the
 * field itself) back to `undefined` when nothing remains, so docs
 * without any hides round-trip clean. */
function withoutId(
  field: RowHiddenLike,
  category: VisCategory,
  id: string,
): RowHiddenLike {
  const current = field?.[category];
  if (!current || !current.includes(id)) return field;
  const nextList = current.filter((x) => x !== id);
  const next = { ...(field ?? {}) };
  if (nextList.length === 0) delete next[category];
  else next[category] = nextList;
  const anyEntry = next.peers !== undefined ||
    next.sessions !== undefined ||
    next.messages !== undefined;
  return anyEntry ? next : undefined;
}

/** Add `id` to `field[category]` (idempotent — no-op when already
 * present). Returns the same kind of pruned shape as `withoutId`. */
function withId(
  field: RowHiddenLike,
  category: VisCategory,
  id: string,
): RowHiddenLike {
  const current = field?.[category] ?? [];
  if (current.includes(id)) return field;
  const next = { ...(field ?? {}) };
  next[category] = [...current, id];
  return next;
}

/** Apply a per-entity visibility mode in-place on `doc`. The three
 * doc arrays are mutually exclusive — clear from all three first,
 * then write into the bucket for the target mode. `"visible"` is
 * the absence-from-all case. */
export function setRowVisModeOnDoc(
  doc: TimelineDocument,
  category: VisCategory,
  id: string,
  mode: VisMode,
): void {
  doc.rowHidden = withoutId(doc.rowHidden, category, id);
  doc.rowLabelHidden = withoutId(doc.rowLabelHidden, category, id);
  doc.rowBodyHidden = withoutId(doc.rowBodyHidden, category, id);
  switch (mode) {
    case "visible":
      return;
    case "both":
      doc.rowHidden = withId(doc.rowHidden, category, id);
      return;
    case "label":
      doc.rowLabelHidden = withId(doc.rowLabelHidden, category, id);
      return;
    case "body":
      doc.rowBodyHidden = withId(doc.rowBodyHidden, category, id);
      return;
  }
}

/** Apply a category-level visibility flag in-place on `doc`.
 * Returns `true` if the doc changed (caller decides whether to
 * notify). */
export function setCategoryVisModeOnDoc(
  doc: TimelineDocument,
  category: VisCategory,
  mode: VisMode,
): boolean {
  const prev = doc.categoryVisMode?.[category] ?? "visible";
  if (prev === mode) return false;
  const next = { ...(doc.categoryVisMode ?? {}) };
  if (mode === "visible") delete next[category];
  else next[category] = mode;
  doc.categoryVisMode = next.peers === undefined && next.sessions === undefined &&
      next.messages === undefined
    ? undefined
    : next;
  return true;
}

/** Apply an all-rows visibility flag in-place on `doc`. Returns
 * `true` if the doc changed. */
export function setAllVisModeOnDoc(
  doc: TimelineDocument,
  mode: VisMode,
): boolean {
  const prev = doc.allVisMode ?? "visible";
  if (prev === mode) return false;
  doc.allVisMode = mode === "visible" ? undefined : mode;
  return true;
}

/** Per-entity stored mode — what the user set on the entity
 * eyeball. NOT composed with category / all. */
export function rowVisModeOnDoc(
  doc: TimelineDocument,
  category: VisCategory,
  id: string,
): VisMode {
  if (doc.rowHidden?.[category]?.includes(id)) return "both";
  if (doc.rowLabelHidden?.[category]?.includes(id)) return "label";
  if (doc.rowBodyHidden?.[category]?.includes(id)) return "body";
  return "visible";
}

/** Stored category flag — what the user set on the category
 * eyeball. NOT a roll-up of entity flags. */
export function categoryVisModeOnDoc(
  doc: TimelineDocument,
  category: VisCategory,
): VisMode {
  return doc.categoryVisMode?.[category] ?? "visible";
}

/** Stored all-rows flag. NOT a roll-up of category flags. */
export function allVisModeOnDoc(doc: TimelineDocument): VisMode {
  return doc.allVisMode ?? "visible";
}

/** Next slot in the per-entity / category / all-rows visibility
 * cycle. All three eyeball cycles share this vocabulary:
 * `visible → label → body → both → visible`. No "mixed" state —
 * each level stores its own flag and doesn't survey the levels
 * below. UI callers that drive the eyeball click pipe through here. */
export function nextVisCycleStep(current: VisMode): VisMode {
  switch (current) {
    case "visible":
      return "label";
    case "label":
      return "body";
    case "body":
      return "both";
    case "both":
      return "visible";
  }
}

/** Decompose a `VisMode` into the two independent axis bits it
 *  represents: whether the label is hidden, and whether the body is
 *  hidden. `"visible"` is `{ false, false }`; `"both"` is `{ true,
 *  true }`. Used by `effectiveRowVisMode` to compose levels by
 *  OR-ing axes rather than picking a winner. */
function bitsFor(
  mode: VisMode,
): { readonly hideLabel: boolean; readonly hideBody: boolean } {
  switch (mode) {
    case "visible":
      return { hideLabel: false, hideBody: false };
    case "label":
      return { hideLabel: true, hideBody: false };
    case "body":
      return { hideLabel: false, hideBody: true };
    case "both":
      return { hideLabel: true, hideBody: true };
  }
}

/** Inverse of `bitsFor`. */
function modeFor(
  hideLabel: boolean,
  hideBody: boolean,
): VisMode {
  if (hideLabel && hideBody) return "both";
  if (hideLabel) return "label";
  if (hideBody) return "body";
  return "visible";
}

/** Effective per-entity visibility for rendering. Composes the three
 *  levels (`all → category → entity`) by OR-ing each axis: a label is
 *  hidden if ANY level hides it, body likewise. Matches the
 *  Photoshop / Figma / DAW convention — parents can ADD hides,
 *  children can ADD more hides, no level can ever UNHIDE what
 *  another level hid. This is what makes per-level toggles feel like
 *  layer-style visibility controls instead of override switches.
 *
 *  Per-axis OR-of-levels also means a category set to `"label"` plus
 *  an entity set to `"body"` compose to `"both"` rather than letting
 *  the entity override and forfeit the label-hide. The pre-fix code
 *  was winner-take-all (first non-`visible` level won); that
 *  conflated three independent axis decisions into one. */
export function effectiveRowVisMode(
  doc: TimelineDocument,
  category: VisCategory,
  id: string,
): VisMode {
  const all = bitsFor(allVisModeOnDoc(doc));
  const cat = bitsFor(categoryVisModeOnDoc(doc, category));
  const row = bitsFor(rowVisModeOnDoc(doc, category, id));
  return modeFor(
    all.hideLabel || cat.hideLabel || row.hideLabel,
    all.hideBody || cat.hideBody || row.hideBody,
  );
}
