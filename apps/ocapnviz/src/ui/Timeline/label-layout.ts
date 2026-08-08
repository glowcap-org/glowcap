/**
 * Lane-label layout: pure geometry, no React, no Graphics. The
 * Scrubber's `drawLaneSpans` calls `layoutLaneLabels` to decide
 * which labels survive a dense cluster and where they paint.
 *
 * Sticky-header semantics (variation 1): right-to-left single pass.
 * Later spans claim space first; earlier ones shrink and eventually
 * drop. Stable sort on `(startT, id)` keeps frames reproducible.
 */

/** Horizontal padding inside a pill, before label start / after end. */
export const LABEL_INSET_PX = 5;
/** Min horizontal gap between two adjacent labels in a lane. */
export const LABEL_GAP_PX = 4;
/** Below this available width, drop the label rather than render
 * a useless ellipsis-only smudge. */
export const LABEL_MIN_PX = 6;
/** How wide one character of Departure Mono is, as a share of the type
 *  size: five eighths of the em, one width for the whole family. */
const MONO_ADVANCE_RATIO = 0.625;

/** How wide one character of the mono face is at `fontSizePx`, in CSS
 * px. Exported so every fit calculation and its tests share one
 * source of truth.
 *
 * Whole pixels, because Departure Mono is drawn on a pixel grid and
 * the browser lands its advance on one: at 9 px a character occupies
 * 6 px, not the 5.625 the ratio alone predicts. That rounding is the
 * difference between a label that stops inside its column and one
 * that runs past the edge, because the error compounds once per
 * character — under-measuring by half a pixel overhangs a
 * ten-character row label by five.
 *
 * A machine that never loaded the face falls back to a monospace with
 * true 0.6-em metrics and no rounding. At the 9 px the timeline sets,
 * that is 5.4 px against the 6 px measured here, so the fallback
 * elides a character early rather than spilling.
 */
export function monoAdvance(fontSizePx: number): number {
  return Math.round(fontSizePx * MONO_ADVANCE_RATIO);
}

export type LaneLabelInput = {
  id: string;
  startT: number;
  label: string | undefined;
  /** Visible-window-clipped pill edges, in plot px. */
  pillLeft: number;
  pillRight: number;
};

export type PlacedLabel = {
  id: string;
  x: number;
  /** May be truncated with a trailing `…`. */
  label: string;
};

/**
 * Right-to-left, single-pass label layout for a lane.
 *
 *   - Labels are anchored to their pill's left edge
 *     (`pillLeft + LABEL_INSET_PX`).
 *   - The right edge of each label is clipped to the tighter of
 *     two constraints: its own pill's right edge
 *     (`pillRight - LABEL_INSET_PX`) and the next placed label's
 *     left edge (minus `LABEL_GAP_PX`).
 *   - When the full label fits, it renders unchanged. Otherwise
 *     it's truncated with ellipsis to fit the available width.
 *     If less than `LABEL_MIN_PX` is available, the label is
 *     dropped entirely.
 */
export function layoutLaneLabels(
  inputs: readonly LaneLabelInput[],
  advance: number,
  gap: number,
  minWidth: number,
): PlacedLabel[] {
  // Sort by (startT, id). Mutating a copy keeps the caller's
  // array untouched and the sort stable across runs.
  const sorted = inputs.slice().sort((a, b) => {
    if (a.startT !== b.startT) return a.startT - b.startT;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
  // Output is collected back-to-front then reversed so the caller
  // gets a paint-order-friendly left-to-right list.
  const reversed: PlacedLabel[] = [];
  let rightBoundary = Number.POSITIVE_INFINITY;
  for (let i = sorted.length - 1; i >= 0; i--) {
    const input = sorted[i]!;
    if (!input.label) continue;
    const leftAnchor = input.pillLeft + LABEL_INSET_PX;
    const pillRightLimit = input.pillRight - LABEL_INSET_PX;
    const crossLimit = rightBoundary - gap;
    const rightLimit = Math.min(pillRightLimit, crossLimit);
    const available = rightLimit - leftAnchor;
    if (available < minWidth) continue;
    const naturalWidth = input.label.length * advance;
    const placedLabel = naturalWidth <= available
      ? input.label
      : truncateToWidth(input.label, available, advance);
    if (placedLabel.length === 0) continue;
    reversed.push({ id: input.id, x: leftAnchor, label: placedLabel });
    rightBoundary = leftAnchor;
  }
  return reversed.reverse();
}

/**
 * Truncate `label` so it fits in `maxWidth` CSS px at the given
 * monospace `advance`. Appends `…` when truncation occurs. Returns
 * the empty string only if even a single `…` glyph doesn't fit —
 * callers should treat empty as "drop this label."
 *
 * A cut that lands after a space drops it, so a name reads
 * "Archive…" rather than "Archive …", where the gap looks like the
 * word ended and something else was cut.
 */
export function truncateToWidth(
  label: string,
  maxWidth: number,
  advance: number,
): string {
  const naturalWidth = label.length * advance;
  if (naturalWidth <= maxWidth) return label;
  const ellipsis = "…";
  const ellipsisWidth = advance;
  if (ellipsisWidth > maxWidth) return "";
  const charsAvailable = Math.floor((maxWidth - ellipsisWidth) / advance);
  if (charsAvailable <= 0) return ellipsis;
  return label.slice(0, charsAvailable).trimEnd() + ellipsis;
}
