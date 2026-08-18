/**
 * Double-click qualification: two downs on the same entity surface
 * inside the window, and the cases that must not qualify.
 */

import { assert, assertEquals } from "@std/assert";
import { dummyHit } from "../gesture-resolver.ts";
import { pointerReducer } from "../pointer-machine.ts";
import { IDLE_MACHINE } from "../types.ts";
import { dispatch, gctx, snap } from "./harness.ts";

// ─────────────────────── Double-click qualification ───────────────────

Deno.test("two pointer-down/up within 300ms on same peer → emits double-click", () => {
  // First click
  const { state: s1 } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-peer",
      snapshot: snap({ timestampMs: 1000 }),
      ctx: gctx({ hit: dummyHit("stage-peer") }),
    },
    {
      kind: "pointer-up",
      snapshot: snap({ timestampMs: 1050 }),
      ctxAtUp: gctx({ hit: dummyHit("stage-peer") }),
    },
  ]);
  assert(s1.lastUp !== null);
  // Second click within window/distance
  const r = pointerReducer(s1, {
    kind: "pointer-down",
    surface: "stage-peer",
    snapshot: snap({ timestampMs: 1200 }),
    ctx: gctx({ hit: dummyHit("stage-peer") }),
  });
  assertEquals(r.state.fsm.kind, "idle");
  assertEquals(r.state.lastUp, null);
  assertEquals(r.effects.length, 1);
  const eff = r.effects[0]!;
  assert(eff.kind === "double-click");
  assertEquals(eff.entity.kind, "peer");
});

Deno.test("second click after 300ms → does NOT double-click; pressed normally", () => {
  const { state: s1 } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-peer",
      snapshot: snap({ timestampMs: 1000 }),
      ctx: gctx({ hit: dummyHit("stage-peer") }),
    },
    {
      kind: "pointer-up",
      snapshot: snap({ timestampMs: 1050 }),
      ctxAtUp: gctx({ hit: dummyHit("stage-peer") }),
    },
  ]);
  const r = pointerReducer(s1, {
    kind: "pointer-down",
    surface: "stage-peer",
    snapshot: snap({ timestampMs: 1500 }), // 450ms later
    ctx: gctx({ hit: dummyHit("stage-peer") }),
  });
  assertEquals(r.state.fsm.kind, "pressed");
  assertEquals(r.effects, []);
});

Deno.test("second click on different surface → does NOT double-click", () => {
  const { state: s1 } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-peer",
      snapshot: snap({ timestampMs: 1000 }),
      ctx: gctx({ hit: dummyHit("stage-peer") }),
    },
    {
      kind: "pointer-up",
      snapshot: snap({ timestampMs: 1050 }),
      ctxAtUp: gctx({ hit: dummyHit("stage-peer") }),
    },
  ]);
  const r = pointerReducer(s1, {
    kind: "pointer-down",
    surface: "stage-empty", // different surface
    snapshot: snap({ timestampMs: 1100 }),
    ctx: gctx({ hit: dummyHit("stage-empty") }),
  });
  assertEquals(r.state.fsm.kind, "pressed");
});

Deno.test("double-click only qualifies on entity surfaces (not gutter)", () => {
  const { state: s1 } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "timeline-gutter-chevron",
      snapshot: snap({ timestampMs: 1000 }),
      ctx: gctx({ hit: dummyHit("timeline-gutter-chevron") }),
    },
    {
      kind: "pointer-up",
      snapshot: snap({ timestampMs: 1050 }),
      ctxAtUp: gctx({ hit: dummyHit("timeline-gutter-chevron") }),
    },
  ]);
  const r = pointerReducer(s1, {
    kind: "pointer-down",
    surface: "timeline-gutter-chevron",
    snapshot: snap({ timestampMs: 1100 }),
    ctx: gctx({ hit: dummyHit("timeline-gutter-chevron") }),
  });
  // Should enter pressed normally, not emit double-click
  assertEquals(r.state.fsm.kind, "pressed");
});
