/**
 * The camera's bounds, the view a document opens at, and what the controls do.
 *
 * A document is an input, so the interesting cases here are the dishonest
 * ones: a scale a hand-edited file names that this build will not go to, and a
 * center that is not a number. Both have to open at something usable rather
 * than refuse or produce a viewport nobody can pan.
 */

import { assert, assertAlmostEquals, assertEquals } from "@std/assert";
import {
  canStepIn,
  canStepOut,
  clampStageZoom,
  DEFAULT_STAGE_VIEW,
  fitStageView,
  formatStageZoom,
  initialStageView,
  MAX_STAGE_SCALE,
  MIN_STAGE_SCALE,
  parseStageZoom,
  steppedStageZoom,
  unionBounds,
} from "./stage-view.ts";

Deno.test("a document that says nothing opens at the default", () => {
  assertEquals(initialStageView(undefined), DEFAULT_STAGE_VIEW);
});

Deno.test("a document opens at the view it stored", () => {
  const view = { zoom: 0.25, center: { x: 120, y: -80 } };
  assertEquals(initialStageView(view), view);
});

Deno.test("a stored scale outside the bounds opens at the nearest one", () => {
  // Both directions, because a hand-edited file can name either.
  assertEquals(
    initialStageView({ zoom: MIN_STAGE_SCALE / 1000, center: { x: 0, y: 0 } })
      .zoom,
    MIN_STAGE_SCALE,
  );
  assertEquals(
    initialStageView({ zoom: MAX_STAGE_SCALE * 1000, center: { x: 0, y: 0 } })
      .zoom,
    MAX_STAGE_SCALE,
  );
});

Deno.test("the ceiling is out of reach rather than in the way", () => {
  // Where it is matters more than that it exists: the point of the ceiling is
  // that no scale anyone works at is near it. A magnification nobody asks for
  // is held; one somebody might is not.
  assertEquals(clampStageZoom(MAX_STAGE_SCALE * 5), MAX_STAGE_SCALE);
  assertEquals(clampStageZoom(20), 20, "20x is a close read, not the ceiling");
  assertEquals(formatStageZoom(MAX_STAGE_SCALE), "9999%");
});

Deno.test("a nonsense scale opens at the default rather than breaking", () => {
  for (const bad of [0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
    assertEquals(
      clampStageZoom(bad),
      DEFAULT_STAGE_VIEW.zoom,
      `${bad} should fall back to the default scale`,
    );
  }
});

Deno.test("a center that is not a number opens at the origin", () => {
  const opened = initialStageView({
    zoom: 1,
    center: { x: Number.NaN, y: Number.POSITIVE_INFINITY },
  });
  assertEquals(opened.center, { x: 0, y: 0 });
});

Deno.test("a scale reads as a percentage a person can use", () => {
  assertEquals(formatStageZoom(1), "100%");
  assertEquals(formatStageZoom(4), "400%");
  assertEquals(formatStageZoom(0.25), "25%");
  // Below ten percent the tenth matters, because whole percents would show a
  // long stretch of the range as the same number.
  assertEquals(formatStageZoom(0.055), "5.5%");
  // The floor still reads as something rather than rounding to nothing.
  assert(formatStageZoom(MIN_STAGE_SCALE) !== "0%");
});

Deno.test("a step in and a step back out return to where they started", () => {
  // The two directions are one factor, so a reader who overshoots gets back
  // exactly rather than approximately. Nothing else in the controls is
  // reversible, so if this drifts it drifts silently.
  for (const from of [1, 0.4, 2.5, 17]) {
    const there = steppedStageZoom(from, false);
    assert(there > from, `a step in did not move from ${from}`);
    assertAlmostEquals(steppedStageZoom(there, true), from, 1e-12);
  }
});

Deno.test("stepping stops at each bound and says so", () => {
  // The button greys rather than pretending: a control that looks live and does
  // nothing is worse than one that looks spent. Both ends, because a button that
  // greys at one and not the other is the half-built version of this.
  assertEquals(steppedStageZoom(MIN_STAGE_SCALE, true), MIN_STAGE_SCALE);
  assertEquals(canStepOut(MIN_STAGE_SCALE), false);
  assert(canStepOut(MIN_STAGE_SCALE * 2));

  assertEquals(steppedStageZoom(MAX_STAGE_SCALE, false), MAX_STAGE_SCALE);
  assertEquals(canStepIn(MAX_STAGE_SCALE), false);
  assert(canStepIn(MAX_STAGE_SCALE / 2));

  // And in the middle, where the reader actually is, both directions move.
  assert(canStepIn(1) && canStepOut(1));
});

Deno.test("fit shows the whole content, and the tighter axis decides", () => {
  // Wide content in a square viewport is held by its width; the same content
  // turned on its side is held by its height. Whichever runs out first is the
  // scale, or the fit would crop the other axis.
  const wide = fitStageView(
    { x: 0, y: 0, width: 1000, height: 100 },
    { width: 500, height: 500 },
    0,
  );
  assertAlmostEquals(wide.zoom, 0.5, 1e-12);
  const tall = fitStageView(
    { x: 0, y: 0, width: 100, height: 1000 },
    { width: 500, height: 500 },
    0,
  );
  assertAlmostEquals(tall.zoom, 0.5, 1e-12);
  // And it centers on the content rather than on the world.
  assertEquals(
    fitStageView(
      { x: 200, y: -400, width: 100, height: 200 },
      { width: 500, height: 500 },
      0,
    ).center,
    { x: 250, y: -300 },
  );
});

Deno.test("fit leaves the padding it is asked for", () => {
  // The padding is screen pixels, so it comes off the viewport before the
  // division rather than out of the world afterwards.
  const view = fitStageView(
    { x: 0, y: 0, width: 100, height: 100 },
    { width: 300, height: 300 },
    50,
  );
  // 300 less fifty either side is 200 of usable screen for 100 of world.
  assertAlmostEquals(view.zoom, 2, 1e-12);
});

Deno.test("content with no extent still centers on itself", () => {
  // One node, or a row of nodes at one y. An axis with no extent cannot name a
  // scale — it would divide by zero and fit at infinity — so it is skipped, and
  // content with no extent at all keeps the default and just centers.
  const flat = fitStageView(
    { x: -50, y: 10, width: 100, height: 0 },
    { width: 400, height: 400 },
    0,
  );
  assertAlmostEquals(flat.zoom, 4, 1e-12);
  assertEquals(flat.center, { x: 0, y: 10 });

  const point = fitStageView(
    { x: 7, y: 9, width: 0, height: 0 },
    { width: 400, height: 400 },
    0,
  );
  assertEquals(point.zoom, DEFAULT_STAGE_VIEW.zoom);
  assertEquals(point.center, { x: 7, y: 9 });
});

Deno.test("a viewport too small for its padding still answers", () => {
  // Mid-layout, a pane can be narrower than the margin asked of it. Subtracting
  // anyway would name a negative scale.
  const view = fitStageView(
    { x: 0, y: 0, width: 100, height: 100 },
    { width: 10, height: 10 },
    50,
  );
  assertEquals(view.zoom, DEFAULT_STAGE_VIEW.zoom);
  assertEquals(view.center, { x: 50, y: 50 });
});

Deno.test("fit never names a scale the camera cannot reach", () => {
  // Content vast enough to want less than the floor is content the camera
  // cannot show whole, and the honest answer is the floor rather than a scale
  // `clampZoom` will quietly override.
  const view = fitStageView(
    { x: 0, y: 0, width: 10_000_000, height: 10_000_000 },
    { width: 800, height: 600 },
    24,
  );
  assertEquals(view.zoom, MIN_STAGE_SCALE);
});

Deno.test("a union covers every rectangle it is given", () => {
  assertEquals(
    unionBounds([
      { x: 0, y: 0, width: 10, height: 10 },
      { x: 100, y: -50, width: 10, height: 10 },
    ]),
    { x: 0, y: -50, width: 110, height: 60 },
  );
  // One rectangle is its own union, and none is nothing to fit rather than a
  // rectangle at the origin.
  assertEquals(unionBounds([{ x: 5, y: 5, width: 1, height: 1 }]), {
    x: 5,
    y: 5,
    width: 1,
    height: 1,
  });
  assertEquals(unionBounds([]), null);
});

Deno.test("an empty layer's bounds would drag the fit back to the origin", () => {
  // The trap `unionBounds` exists to make visible. An empty Pixi container
  // reports bounds at the origin, which is a real point, so a caller that folds
  // one in fits a document far from the origin plus a long walk back to it.
  // Here that is the difference between fitting 20 units and fitting 320.
  const drawn = { x: 300, y: 300, width: 20, height: 20 };
  const emptyLayer = { x: 0, y: 0, width: 0, height: 0 };
  const right = unionBounds([drawn]);
  const wrong = unionBounds([drawn, emptyLayer]);
  assertEquals(right, drawn);
  assertEquals(wrong, { x: 0, y: 0, width: 320, height: 320 });
  assert(right !== null && wrong !== null, "both unions hold a rectangle");
  const size = { width: 400, height: 400 };
  assert(
    fitStageView(right, size, 0).zoom > fitStageView(wrong, size, 0).zoom * 10,
    "folding an empty layer in should cost most of the zoom, or this case is " +
      "not measuring the trap",
  );
});

Deno.test("a typed zoom is read as the percentage the field shows", () => {
  // The field shows "50%", so "50" means half size. Reading it as a raw scale
  // would send a reader who typed what they saw to fifty times.
  assertAlmostEquals(parseStageZoom("50")!, 0.5, 1e-12);
  assertAlmostEquals(parseStageZoom("100")!, 1, 1e-12);
  assertAlmostEquals(parseStageZoom("400")!, 4, 1e-12);
  // The sign comes back when a reader retypes the whole value, so it is accepted.
  assertAlmostEquals(parseStageZoom(" 50 % ")!, 0.5, 1e-12);
  assertAlmostEquals(parseStageZoom("5.5%")!, 0.055, 1e-12);
});

Deno.test("what is not a scale is refused rather than guessed", () => {
  // Null leaves the camera where it is. Zero and negatives are not scales, and an
  // empty field is a reader who cleared it rather than one who asked for nothing.
  for (const text of ["", "   ", "abc", "%", "-50", "0", "0%"]) {
    assertEquals(parseStageZoom(text), null, `"${text}" was read as a scale`);
  }
});

Deno.test("a typed zoom past a bound goes as far as the camera goes", () => {
  // Clamped rather than refused: asking for more than the camera has is a
  // reasonable thing to ask, and the answer is the end of the range.
  assertEquals(parseStageZoom("0.001"), MIN_STAGE_SCALE);
  assertEquals(parseStageZoom("99999"), MAX_STAGE_SCALE);
  // What the field itself shows round-trips, at both ends, because the reader
  // edits that text: `formatInput` hands `formatStageZoom`'s output straight
  // back to this parser (`ui/StageControls.tsx`).
  for (const zoom of [MIN_STAGE_SCALE, 0.375, 1, 2.5, MAX_STAGE_SCALE]) {
    const back = parseStageZoom(formatStageZoom(zoom));
    assert(back !== null, `"${formatStageZoom(zoom)}" did not read back`);
    assertAlmostEquals(back, zoom, zoom * 0.02);
  }
});
