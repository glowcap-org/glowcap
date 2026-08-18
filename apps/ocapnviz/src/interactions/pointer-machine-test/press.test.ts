/**
 * Pressed, dragging, click: the machine's ordinary down-move-up path,
 * including the click that re-resolves modifiers at pointer-up.
 */

import { assert, assertEquals } from "@std/assert";
import { dummyHit } from "../gesture-resolver.ts";
import { pointerReducer } from "../pointer-machine.ts";
import { IDLE_MACHINE } from "../types.ts";
import { dispatch, gctx, snap } from "./harness.ts";

// ─────────────────────── Basic transitions (§ 5.3) ───────────────────

Deno.test("idle + pointer-down → pressed; no effects", () => {
  const r = pointerReducer(IDLE_MACHINE, {
    kind: "pointer-down",
    surface: "stage-peer",
    snapshot: snap(),
    ctx: gctx({ hit: dummyHit("stage-peer") }),
  });
  assertEquals(r.state.fsm.kind, "pressed");
  assertEquals(r.effects, []);
});

Deno.test("pressed + small move → still pressed", () => {
  const { state } = dispatch(IDLE_MACHINE, [{
    kind: "pointer-down",
    surface: "stage-peer",
    snapshot: snap({ clientX: 100, clientY: 100 }),
    ctx: gctx({ hit: dummyHit("stage-peer") }),
  }]);
  const r = pointerReducer(state, {
    kind: "pointer-move",
    snapshot: snap({ clientX: 102, clientY: 102 }), // 2.8 px < 4
    hit: dummyHit("stage-peer"),
  });
  assertEquals(r.state.fsm.kind, "pressed");
  assertEquals(r.effects, []);
});

/**
 * The move that crosses the threshold both starts the drag AND is the drag's
 * first move, so it reports both.
 *
 * This used to emit `drag-start` alone, which loses the position it crossed at.
 * A consumer following the pointer through `drag-move` hears nothing about it,
 * which is invisible while more moves follow and is the entire gesture when none
 * do: a browser coalesces moves as it likes, so a fast flick can cross the
 * threshold and release with exactly one move between. The marquee then
 * committed the degenerate rect it painted at the press and selected nothing.
 *
 * Measured in a browser before and after, driving the whole stage with one move
 * and a release: nothing selected, then all six entities, matching the same drag
 * delivered in thirty moves. The invariant is that last equality — what a gesture
 * does must not depend on how the browser chose to batch it.
 */
Deno.test("pressed + big move → dragging; starts and moves", () => {
  const { state } = dispatch(IDLE_MACHINE, [{
    kind: "pointer-down",
    surface: "stage-peer",
    snapshot: snap({ clientX: 100, clientY: 100 }),
    ctx: gctx({ hit: dummyHit("stage-peer") }),
  }]);
  const r = pointerReducer(state, {
    kind: "pointer-move",
    snapshot: snap({ clientX: 110, clientY: 100 }), // 10 px
    hit: dummyHit("stage-peer"),
  });
  assertEquals(r.state.fsm.kind, "dragging");
  assertEquals(r.effects.map((e) => e.kind), ["drag-start", "drag-move"]);
  // The start is the press, and the move is where the pointer actually is —
  // reversing them, or reporting the press twice, is the defect in another form.
  const [start, move] = r.effects;
  assert(start?.kind === "drag-start" && "at" in start);
  assert(move?.kind === "drag-move" && "at" in move);
  assertEquals([start.at.clientX, start.at.clientY], [100, 100]);
  assertEquals([move.at.clientX, move.at.clientY], [110, 100]);
});

Deno.test("one big move leaves the same trail as several small ones", () => {
  // THE invariant: a browser coalesces pointer moves as it pleases, so what a
  // gesture does must not depend on how it chose to batch this one. Only the
  // number of intermediate moves differs between these two.
  const down = {
    kind: "pointer-down" as const,
    surface: "stage-empty" as const,
    snapshot: snap({ clientX: 0, clientY: 0 }),
    ctx: gctx({ hit: dummyHit("stage-empty") }),
  };
  const moveTo = (clientX: number, clientY: number) => ({
    kind: "pointer-move" as const,
    snapshot: snap({ clientX, clientY }),
    hit: dummyHit("stage-empty"),
  });
  const up = {
    kind: "pointer-up" as const,
    snapshot: snap({ clientX: 300, clientY: 200, timestampMs: 1200 }),
    ctxAtUp: gctx({ hit: dummyHit("stage-empty") }),
  };
  const oneMove = dispatch(IDLE_MACHINE, [down, moveTo(300, 200), up]);
  const manyMoves = dispatch(IDLE_MACHINE, [
    down,
    moveTo(100, 67),
    moveTo(200, 133),
    moveTo(300, 200),
    up,
  ]);
  // Same kinds in the same order, and the same place the drag ended up.
  assertEquals(oneMove.effects.map((e) => e.kind), [
    "drag-start",
    "drag-move",
    "drag-end",
  ]);
  assertEquals(
    manyMoves.effects.map((e) => e.kind).filter((k, i, a) => k !== "drag-move" || a[i - 1] !== "drag-move"),
    ["drag-start", "drag-move", "drag-end"],
  );
  const lastMove = (r: typeof oneMove) => r.effects.filter((e) => e.kind === "drag-move").at(-1);
  const a = lastMove(oneMove), b = lastMove(manyMoves);
  assert(a && "at" in a && b && "at" in b);
  assertEquals([a.at.clientX, a.at.clientY], [b.at.clientX, b.at.clientY]);
});

Deno.test("pressed + pointer-up → idle; emits click", () => {
  const { state } = dispatch(IDLE_MACHINE, [{
    kind: "pointer-down",
    surface: "stage-peer",
    snapshot: snap(),
    ctx: gctx({ hit: dummyHit("stage-peer") }),
  }]);
  const r = pointerReducer(state, {
    kind: "pointer-up",
    snapshot: snap({ timestampMs: 1100 }),
    ctxAtUp: gctx({ hit: dummyHit("stage-peer") }),
  });
  assertEquals(r.state.fsm.kind, "idle");
  assertEquals(r.effects.length, 1);
  assertEquals(r.effects[0]!.kind, "click");
  // lastUp set for double-click qualification
  assert(r.state.lastUp !== null);
});

Deno.test("dragging + pointer-up → idle; emits drag-end", () => {
  const { state } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-empty",
      snapshot: snap({ clientX: 0, clientY: 0 }),
      ctx: gctx({ hit: dummyHit("stage-empty") }),
    },
    {
      kind: "pointer-move",
      snapshot: snap({ clientX: 50, clientY: 50 }),
      hit: dummyHit("stage-empty"),
    },
  ]);
  const r = pointerReducer(state, {
    kind: "pointer-up",
    snapshot: snap({ clientX: 50, clientY: 50, timestampMs: 1200 }),
    ctxAtUp: gctx({ hit: dummyHit("stage-empty") }),
  });
  assertEquals(r.state.fsm.kind, "idle");
  assertEquals(r.effects[0]!.kind, "drag-end");
});

// ─────────────────────── Click re-resolve (D / F4) ───────────────────

Deno.test("F4: pointer-down no-mod + pointer-up with shift → click verb is shift-augmented", () => {
  const hit = dummyHit("stage-peer", { peerId: "alice" });
  const { state } = dispatch(IDLE_MACHINE, [{
    kind: "pointer-down",
    surface: "stage-peer",
    snapshot: snap(),
    ctx: gctx({ hit }),
  }]);
  const r = pointerReducer(state, {
    kind: "pointer-up",
    snapshot: snap({ timestampMs: 1100 }),
    ctxAtUp: gctx({
      hit,
      modifiers: { shift: true, cmd: false, alt: false },
    }),
  });
  const click = r.effects[0];
  assert(click && click.kind === "click");
  assertEquals(click.verb.tier, "modifier");
  if (click.verb.tier === "modifier") {
    assertEquals(click.verb.modifier, "shift");
    assertEquals(click.verb.verb.kind, "extend-selection-range");
  }
});
