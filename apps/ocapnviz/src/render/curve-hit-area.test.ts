import { assert, assertEquals } from "@std/assert";
import { curveBoundsArea, curveHitArea } from "./curve-hit-area.ts";

Deno.test("curve hit area accepts points on the chord and rejects far ones", () => {
  const hit = curveHitArea(
    { ax: 0, ay: 0, bx: 100, by: 0, cx: 50, cy: 0 },
    3,
  );
  assert(hit.contains(50, 0), "midpoint of a flat curve");
  assert(hit.contains(50, 2), "within half-width");
  assertEquals(hit.contains(50, 3.1), false, "outside half-width");
  assertEquals(hit.contains(50, 20), false, "far from the wire");
  assertEquals(hit.contains(-40, 0), false, "past the start");
});

Deno.test("curve hit half-width matches the stroke, not a padded floor", () => {
  // Closed sessions stroke at width 1; a hidden floor of several world
  // units would make every thin wire a fat target.
  const hit = curveHitArea(
    { ax: 0, ay: 0, bx: 40, by: 0, cx: 20, cy: 0 },
    0.5,
  );
  assert(hit.contains(20, 0), "on the ink");
  assertEquals(hit.contains(20, 2), false, "well outside a hairline");
});

Deno.test("curve boundsArea covers the sampled wire, not the origin", () => {
  // Unselected edge proxies have no stroked child. Without boundsArea the
  // culler sees origin-empty bounds and drops on-screen wires when the
  // camera is elsewhere.
  const box = curveBoundsArea(
    { ax: 400, ay: 500, bx: 600, by: 500, cx: 500, cy: 520 },
    2,
  );
  assert(box.x < 400, "pad past the start");
  assert(box.x + box.width > 600, "pad past the end");
  assert(box.y < 500, "pad below the chord");
  assertEquals(box.contains(0, 0), false, "origin is not in the cull box");
  assert(box.contains(500, 500), "mid-chord is in the cull box");
});
