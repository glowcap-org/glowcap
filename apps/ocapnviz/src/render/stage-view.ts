/**
 * Where the camera is allowed to go, and where a document asks it to start.
 *
 * Two separate things live here because they answer to each other. The bounds
 * say what a camera may do at all; the document's initial view is one position
 * inside those bounds, so a document that stored a scale the bounds later
 * narrowed has to be clamped rather than trusted.
 *
 * # The bounds
 *
 * A visualizer's job includes both reading a designator on one node and seeing a
 * hand-built document whole, and those are different scales. So the range is very
 * wide, and each end is there for its own reason.
 *
 * The floor stops the viewport degenerating, where world units get small enough
 * that pan and hit-testing lose their footing.
 *
 * The ceiling sits far past any use anyone has for it — one node filling the
 * viewport many times over — so it refuses nothing a reader wants. What it buys is
 * that the scale has two ends. A control that steps can say when a step would not
 * move, and a control that scrubs has something to scrub between; both of those
 * are one-sided while one end is open.
 *
 * # The view a document carries
 *
 * Where a document opens is `initialView` on `TimelineDocument`, and `Stage.tsx`
 * reads it once when it builds the viewport. A document with nothing stored opens
 * at `DEFAULT_STAGE_VIEW`, the middle of the world at 1:1, which is also where the
 * controls' home button goes.
 *
 * Looking around does not set it. Panning and zooming are reading, so they change
 * no document and record no history; what the camera does instead is report where
 * it came to rest (`StageCamera.publishSettledView`), and the document panel's
 * Opens-at row offers to record that with a press
 * (`Engine.setOpeningView`). Setting it is then an ordinary undoable edit, which
 * keeps one rule true across the app: the document changes when a reader changes
 * it, and every change is a step they can walk back.
 */

/**
 * The smallest scale the camera may reach. At 1% a 4000-unit world is 40
 * screen pixels across, which is past useful and close to where fractional
 * world coordinates stop being able to address a pixel.
 */
export const MIN_STAGE_SCALE = 0.01;

/**
 * The largest scale the camera may reach, which reads as 9999%. Chosen for where
 * it is not: nothing a reader does with this tool needs a hundred world units to
 * the pixel, so the ceiling is out of reach rather than in the way, and it is what
 * gives the scale a second end for the controls to work against.
 */
export const MAX_STAGE_SCALE = 99.99;

/** How much one zoom step multiplies or divides the scale. */
export const STAGE_ZOOM_STEP = 1.2;

export type StageView = {
  /** Scale, where 1 is one world unit per screen pixel. */
  zoom: number;
  /** World point held at the center of the viewport. */
  center: { x: number; y: number };
};

export const DEFAULT_STAGE_VIEW: StageView = {
  zoom: 1,
  center: { x: 0, y: 0 },
};

/** Whether two views put the camera in the same place. Field by field, because a
 *  view is three numbers and none of them wants an epsilon: either the camera
 *  republished what it already said, or it moved. */
export function sameStageView(a: StageView, b: StageView): boolean {
  return a.zoom === b.zoom && a.center.x === b.center.x &&
    a.center.y === b.center.y;
}

/**
 * Hold `zoom` inside the bounds above.
 *
 * Applied to a document's stored view as well as to a wheel step, because a
 * document is an input like any other: one written by a build that allowed a
 * different range, or edited by hand, can name a scale this build will not go
 * to. Clamping on the way in means every reader downstream can treat the value
 * as reachable.
 */
export function clampStageZoom(zoom: number): number {
  if (!Number.isFinite(zoom) || zoom <= 0) return DEFAULT_STAGE_VIEW.zoom;
  return Math.min(MAX_STAGE_SCALE, Math.max(MIN_STAGE_SCALE, zoom));
}

/** The view a document opens at: what it stored, clamped, or the default. */
export function initialStageView(
  stored: StageView | undefined,
): StageView {
  if (!stored) return DEFAULT_STAGE_VIEW;
  return {
    zoom: clampStageZoom(stored.zoom),
    center: {
      x: Number.isFinite(stored.center.x) ? stored.center.x : 0,
      y: Number.isFinite(stored.center.y) ? stored.center.y : 0,
    },
  };
}

/** The scale one step further in or out, held inside the bounds. */
export function steppedStageZoom(zoom: number, out: boolean): number {
  const from = clampStageZoom(zoom);
  return clampStageZoom(out ? from / STAGE_ZOOM_STEP : from * STAGE_ZOOM_STEP);
}

/** Whether a step out would move at all, which is what greys the button. Asked
 *  rather than compared against the floor at the call site, so the floor stays
 *  one fact. */
export function canStepOut(zoom: number): boolean {
  return steppedStageZoom(zoom, true) < clampStageZoom(zoom);
}

/** The same question at the other end. Both bounds grey their own button, so
 *  neither reads as live while it cannot move. */
export function canStepIn(zoom: number): boolean {
  return steppedStageZoom(zoom, false) > clampStageZoom(zoom);
}

/** A rectangle in world units — what the stage has actually drawn. */
export type ContentBounds = {
  x: number;
  y: number;
  width: number;
  height: number;
};

/**
 * The rectangle covering all of `rects`, or null when there are none.
 *
 * Fit measures several layers rather than the viewport whole, so it needs to add
 * them up. An EMPTY layer must not be one of them, and that is the trap this
 * exists to make visible: an empty Pixi container reports bounds at the origin,
 * which is a real point, so folding one in stretches the fit back to (0, 0) and
 * a document whose nodes all sit far from the origin fits mostly empty space.
 * Callers pass only the layers that drew something, and no rectangles at all
 * means there is nothing to fit.
 */
export function unionBounds(
  rects: readonly ContentBounds[],
): ContentBounds | null {
  let minX = Number.POSITIVE_INFINITY;
  let minY = Number.POSITIVE_INFINITY;
  let maxX = Number.NEGATIVE_INFINITY;
  let maxY = Number.NEGATIVE_INFINITY;
  for (const r of rects) {
    if (!Number.isFinite(r.x) || !Number.isFinite(r.y)) continue;
    if (!Number.isFinite(r.width) || !Number.isFinite(r.height)) continue;
    minX = Math.min(minX, r.x);
    minY = Math.min(minY, r.y);
    maxX = Math.max(maxX, r.x + r.width);
    maxY = Math.max(maxY, r.y + r.height);
  }
  if (minX > maxX || minY > maxY) return null;
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}

/**
 * The view that shows `content` whole inside a viewport of `size` screen pixels,
 * with `padding` screen pixels of margin on every side.
 *
 * The scale is whichever axis runs out first, so nothing is cropped, and the
 * center is the content's own center. Padding is screen pixels because it is
 * breathing room for a reader rather than a fact about the world.
 *
 * Content with no extent in an axis cannot ask that axis for a scale — a single
 * node, or a row of nodes at one y, would divide by zero and fit at infinity.
 * Such an axis is skipped, and content with no extent at all keeps the default
 * scale and simply centers, which is the most that can be said about it.
 *
 * A viewport too small to hold the padding is a viewport mid-layout, and the
 * answer is the default view rather than a negative scale.
 */
export function fitStageView(
  content: ContentBounds,
  size: { width: number; height: number },
  padding: number,
): StageView {
  const center = {
    x: Number.isFinite(content.x) && Number.isFinite(content.width)
      ? content.x + content.width / 2
      : 0,
    y: Number.isFinite(content.y) && Number.isFinite(content.height)
      ? content.y + content.height / 2
      : 0,
  };
  const usableW = size.width - padding * 2;
  const usableH = size.height - padding * 2;
  if (!(usableW > 0) || !(usableH > 0)) {
    return { zoom: DEFAULT_STAGE_VIEW.zoom, center };
  }
  const scales: number[] = [];
  if (content.width > 0) scales.push(usableW / content.width);
  if (content.height > 0) scales.push(usableH / content.height);
  if (scales.length === 0) {
    return { zoom: DEFAULT_STAGE_VIEW.zoom, center };
  }
  return { zoom: clampStageZoom(Math.min(...scales)), center };
}

/**
 * The scale a reader means by what they typed into the zoom field, or null when
 * they have not typed a scale.
 *
 * A percentage, because a percentage is what the field shows: "50" is half size,
 * not fifty times. A trailing `%` is accepted because a reader who selects the
 * whole value and retypes it will often type the sign back, and refusing that
 * would be refusing the field's own reading.
 *
 * Null for anything that is not a number, so the caller can leave the camera
 * where it is rather than guess. Zero and negatives are not scales at all, and a
 * number below the floor is clamped rather than refused — a reader who asks for
 * more than the camera has goes as far as it goes.
 */
export function parseStageZoom(text: string): number | null {
  const cleaned = text.trim().replace(/%$/, "").trim();
  if (cleaned === "") return null;
  const percent = Number(cleaned);
  if (!Number.isFinite(percent) || percent <= 0) return null;
  return clampStageZoom(percent / 100);
}

/** How a scale reads to a person: a percentage, at a resolution that stays
 *  useful at both ends of a range this wide. Below one percent it would round
 *  to zero, and the bounds stop it getting there. */
export function formatStageZoom(zoom: number): string {
  const pct = zoom * 100;
  if (pct >= 100) return `${Math.round(pct)}%`;
  if (pct >= 10) return `${pct.toFixed(0)}%`;
  return `${pct.toFixed(1)}%`;
}
