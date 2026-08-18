/**
 * The dashed outline that says "a place a peer will attach".
 *
 * It has to close (a gap where a corner should be reads as a broken
 * shape, not a dashed one), and its dashes have to be the same size
 * all the way round, because a side that ran out of room mid-dash
 * and stretched the last one would read as a different weight on
 * that side.
 */

import { assert, assertAlmostEquals } from "@std/assert";
import { strokeDashedRoundRect } from "../draw-helpers.ts";
import { at, RectRecorder } from "./harness.ts";

const STROKE = { color: 0xffffff, width: 2, alpha: 0.9 };

Deno.test("dashed node outline: every dash opens its own sub-path", () => {
  // Same hazard the armed ring has: consecutive segments appended to one
  // live polyline turn each intended gap into a drawn chord, and the
  // outline stops reading as dashed at all.
  const g = new RectRecorder();
  strokeDashedRoundRect(g, 30, 5, STROKE);
  assert(g.dashes().length > 8, `expected dashes, got ${g.dashes().length}`);
  for (let i = 1; i < g.calls.length; i++) {
    const c = at(g.calls, i, "call");
    if (c.op !== "arcTo") continue;
    assert(
      at(g.calls, i - 1, "call").op === "moveTo",
      `corner arc at ${i} continues an open path; its gap renders as a chord`,
    );
  }
});

Deno.test("dashed node outline: dashes never overrun the corners", () => {
  // Each side is walked corner to corner and the last dash is clipped
  // rather than allowed to overshoot, so no dash crosses into the arc that
  // is drawn whole. A dash past the corner would double-draw it at a
  // different angle, which reads as a bent, thickened corner. The radius is
  // chosen so the run is NOT a whole number of dash periods: at a size the
  // last dash happens to land inside, the clip never fires and the test
  // would pass without exercising it.
  const r = 32;
  const corner = 5;
  const g = new RectRecorder();
  strokeDashedRoundRect(g, r, corner, STROKE);
  for (const d of g.dashes()) {
    for (const [x, y] of [[d.x0, d.y0], [d.x1, d.y1]]) {
      assert(
        Math.abs(x!) <= r + 1e-9 && Math.abs(y!) <= r + 1e-9,
        `dash point (${x}, ${y}) outside the ${r}-radius square`,
      );
      // On a side, one coordinate is pinned to the edge and the other
      // stays inside the straight run between the two corner arcs.
      const onEdge = Math.abs(Math.abs(x!) - r) < 1e-9 ||
        Math.abs(Math.abs(y!) - r) < 1e-9;
      assert(onEdge, `dash point (${x}, ${y}) is not on an edge`);
      const along = Math.abs(Math.abs(x!) - r) < 1e-9 ? y! : x!;
      assert(
        Math.abs(along) <= r - corner + 1e-9,
        `dash point (${x}, ${y}) runs into a corner arc`,
      );
    }
  }
});

Deno.test("dashed node outline: all four sides carry the same cadence", () => {
  // A square has four equal runs, so a correct walk produces the same
  // number of dashes on each and the same length for every dash but the
  // clipped last one of a side. Different cadences per side would read as
  // different line weights on a shape the eye takes in at once.
  const g = new RectRecorder();
  // Same not-a-whole-number-of-periods radius as above, so the clipped last
  // dash of each side is present and its four copies have to agree too.
  strokeDashedRoundRect(g, 32, 5, STROKE);
  const lengths = g.dashes().map((d) => Math.hypot(d.x1 - d.x0, d.y1 - d.y0));
  assert(lengths.length % 4 === 0, `sides differ: ${lengths.length} dashes`);
  const perSide = lengths.length / 4;
  for (let i = 0; i < perSide; i++) {
    const first = at(lengths, i, "dash");
    for (let side = 1; side < 4; side++) {
      assertAlmostEquals(
        at(lengths, side * perSide + i, "dash"),
        first,
        1e-9,
        `dash ${i} on side ${side}`,
      );
    }
  }
  // Every dash is the full length except a side's last, which is clipped.
  for (let i = 0; i < perSide - 1; i++) {
    assertAlmostEquals(at(lengths, i, "dash"), 6, 1e-9, `dash ${i}`);
  }
});

Deno.test("dashed node outline: the outline scales with the node it draws", () => {
  // The placeholder stands where a peer's body would, so its outline is
  // world units like the peer's solid one: at twice the radius it has more
  // dashes of the same size, not the same dashes stretched.
  const small = new RectRecorder();
  const big = new RectRecorder();
  strokeDashedRoundRect(small, 30, 5, STROKE);
  strokeDashedRoundRect(big, 60, 5, STROKE);
  assert(
    big.dashes().length > small.dashes().length,
    `dash count did not grow with the node`,
  );
  assertAlmostEquals(small.strokeWidthOf(), big.strokeWidthOf(), 1e-9);
});
