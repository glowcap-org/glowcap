import { assert, assertEquals } from "@std/assert";
import { dummyHit } from "./gesture-resolver.ts";
import { hasSomethingToCommit, pointerReducer } from "./pointer-machine.ts";
import {
  type Effect,
  type GestureContext,
  type Hit,
  IDLE_MACHINE,
  NO_MODIFIERS,
  type PointerEvent_,
  type PointerMachineState,
  type PointerSnapshot,
} from "./types.ts";

// ─────────────────────── Fixtures ─────────────────────────────────────

function snap(opts: Partial<PointerSnapshot> = {}): PointerSnapshot {
  return {
    clientX: 100,
    clientY: 100,
    buttons: 1,
    modifiers: NO_MODIFIERS,
    timestampMs: 1000,
    ...opts,
  };
}

function gctx(opts: Partial<GestureContext> & { hit: Hit }): GestureContext {
  return {
    modifiers: NO_MODIFIERS,
    spaceHeld: false,
    activeTool: "select",
    ...opts,
  };
}

function dispatch(
  state: PointerMachineState,
  events: PointerEvent_[],
): { state: PointerMachineState; effects: Effect[] } {
  let s = state;
  const all: Effect[] = [];
  for (const e of events) {
    const r = pointerReducer(s, e);
    s = r.state;
    all.push(...r.effects);
  }
  return { state: s, effects: all };
}

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

// ─────────────────────── Space mid-press (Figma-convert) ──────────────

Deno.test("pressed + space-down → paused-pan; no drag-pause (no drag in flight)", () => {
  const { state } = dispatch(IDLE_MACHINE, [{
    kind: "pointer-down",
    surface: "stage-empty",
    snapshot: snap(),
    ctx: gctx({ hit: dummyHit("stage-empty") }),
  }]);
  const r = pointerReducer(state, { kind: "space-down" });
  assertEquals(r.state.fsm.kind, "paused-pan");
  assertEquals(r.effects, []);
});

Deno.test("dragging + space-down → paused-pan; emits drag-pause", () => {
  const { state } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-empty",
      snapshot: snap({ clientX: 0, clientY: 0 }),
      ctx: gctx({ hit: dummyHit("stage-empty") }),
    },
    {
      kind: "pointer-move",
      snapshot: snap({ clientX: 50, clientY: 0 }),
      hit: dummyHit("stage-empty"),
    },
  ]);
  const r = pointerReducer(state, { kind: "space-down" });
  assertEquals(r.state.fsm.kind, "paused-pan");
  assertEquals(r.effects[0]!.kind, "drag-pause");
});

Deno.test("paused-pan + pointer-move → pan-step with surface and delta", () => {
  const { state } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-empty",
      snapshot: snap({ clientX: 0, clientY: 0 }),
      ctx: gctx({ hit: dummyHit("stage-empty") }),
    },
    {
      kind: "pointer-move",
      snapshot: snap({ clientX: 50, clientY: 0 }),
      hit: dummyHit("stage-empty"),
    },
    { kind: "space-down" },
  ]);
  const r = pointerReducer(state, {
    kind: "pointer-move",
    snapshot: snap({ clientX: 60, clientY: 5 }),
    hit: dummyHit("stage-empty"),
  });
  assertEquals(r.effects.length, 1);
  const eff = r.effects[0]!;
  assert(eff.kind === "pan-step");
  assertEquals(eff.surface, "stage-empty");
  assertEquals(eff.delta, { dx: 10, dy: 5 });
});

Deno.test("paused-pan + space-up (button held) → dragging; drag-resume with carriedOrigin", () => {
  // Drag, pan, release space while still holding pointer.
  const { state } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-empty",
      snapshot: snap({ clientX: 0, clientY: 0 }),
      ctx: gctx({ hit: dummyHit("stage-empty") }),
    },
    {
      kind: "pointer-move",
      snapshot: snap({ clientX: 50, clientY: 0 }),
      hit: dummyHit("stage-empty"),
    },
    { kind: "space-down" },
    {
      kind: "pointer-move",
      snapshot: snap({ clientX: 60, clientY: 5 }),
      hit: dummyHit("stage-empty"),
    },
  ]);
  const r = pointerReducer(state, {
    kind: "space-up",
    pointerHeld: true,
  });
  assertEquals(r.state.fsm.kind, "dragging");
  const eff = r.effects[0]!;
  assert(eff.kind === "drag-resume");
  // Carried origin = the cursor position at space-up
  assertEquals(eff.carriedOrigin.clientX, 60);
  assertEquals(eff.carriedOrigin.clientY, 5);
});

Deno.test("paused-pan + space-up (button released) → idle; drag-end", () => {
  const { state } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-empty",
      snapshot: snap({ clientX: 0, clientY: 0 }),
      ctx: gctx({ hit: dummyHit("stage-empty") }),
    },
    {
      kind: "pointer-move",
      snapshot: snap({ clientX: 50, clientY: 0 }),
      hit: dummyHit("stage-empty"),
    },
    { kind: "space-down" },
  ]);
  const r = pointerReducer(state, {
    kind: "space-up",
    pointerHeld: false,
  });
  assertEquals(r.state.fsm.kind, "idle");
  assertEquals(r.effects[0]!.kind, "drag-end");
});

Deno.test("paused-pan + pointer-up → idle; drag-end (even if space still held)", () => {
  const { state } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-empty",
      snapshot: snap({ clientX: 0, clientY: 0 }),
      ctx: gctx({ hit: dummyHit("stage-empty") }),
    },
    {
      kind: "pointer-move",
      snapshot: snap({ clientX: 50, clientY: 0 }),
      hit: dummyHit("stage-empty"),
    },
    { kind: "space-down" },
  ]);
  const r = pointerReducer(state, {
    kind: "pointer-up",
    snapshot: snap({ clientX: 60, clientY: 5 }),
    ctxAtUp: gctx({ hit: dummyHit("stage-empty") }),
  });
  assertEquals(r.state.fsm.kind, "idle");
  assertEquals(r.effects[0]!.kind, "drag-end");
});

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

// ─────────────────────── Cancel ───────────────────────────────────────

Deno.test("dragging + cancel → idle; drag-cancel", () => {
  const { state } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-empty",
      snapshot: snap({ clientX: 0, clientY: 0 }),
      ctx: gctx({ hit: dummyHit("stage-empty") }),
    },
    {
      kind: "pointer-move",
      snapshot: snap({ clientX: 50, clientY: 0 }),
      hit: dummyHit("stage-empty"),
    },
  ]);
  const r = pointerReducer(state, { kind: "cancel" });
  assertEquals(r.state.fsm.kind, "idle");
  assertEquals(r.effects[0]!.kind, "drag-cancel");
});

Deno.test("pressed + cancel → idle; no effect", () => {
  const { state } = dispatch(IDLE_MACHINE, [{
    kind: "pointer-down",
    surface: "stage-peer",
    snapshot: snap(),
    ctx: gctx({ hit: dummyHit("stage-peer") }),
  }]);
  const r = pointerReducer(state, { kind: "cancel" });
  assertEquals(r.state.fsm.kind, "idle");
  assertEquals(r.effects, []);
});

// ─────────────────────── Hover tracking ───────────────────────────────

Deno.test("pointer-move updates hover regardless of fsm state", () => {
  const r = pointerReducer(IDLE_MACHINE, {
    kind: "pointer-move",
    snapshot: snap(),
    hit: dummyHit("stage-peer", { peerId: "hovered" }),
  });
  assert(r.state.hover !== null);
  assertEquals(r.state.hover.surface, "stage-peer");
});

Deno.test("pointer-move with null hit → hover cleared", () => {
  const { state } = dispatch(IDLE_MACHINE, [{
    kind: "pointer-move",
    snapshot: snap(),
    hit: dummyHit("stage-peer"),
  }]);
  assert(state.hover !== null);
  const r = pointerReducer(state, {
    kind: "pointer-move",
    snapshot: snap(),
    hit: null,
  });
  assertEquals(r.state.hover, null);
});

// ─────────────────────── F2 (drag-pause → resume/end/cancel) ──────────

Deno.test("F2: drag-pause is followed by drag-resume (space-up + button held)", () => {
  const { effects } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-empty",
      snapshot: snap({ clientX: 0, clientY: 0 }),
      ctx: gctx({ hit: dummyHit("stage-empty") }),
    },
    {
      kind: "pointer-move",
      snapshot: snap({ clientX: 50, clientY: 0 }),
      hit: dummyHit("stage-empty"),
    },
    { kind: "space-down" }, // drag-pause
    { kind: "space-up", pointerHeld: true }, // drag-resume
  ]);
  const kinds = effects.map((e) => e.kind);
  // Drag-start, drag-pause, drag-resume — one resume per pause
  assert(kinds.includes("drag-pause"));
  assert(kinds.includes("drag-resume"));
  const pauses = kinds.filter((k) => k === "drag-pause").length;
  const resumes = kinds.filter((k) => k === "drag-resume").length;
  assertEquals(pauses, resumes);
});

Deno.test("F2: drag-pause is followed by drag-end (space-up + button released)", () => {
  const { effects } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-empty",
      snapshot: snap({ clientX: 0, clientY: 0 }),
      ctx: gctx({ hit: dummyHit("stage-empty") }),
    },
    {
      kind: "pointer-move",
      snapshot: snap({ clientX: 50, clientY: 0 }),
      hit: dummyHit("stage-empty"),
    },
    { kind: "space-down" },
    { kind: "space-up", pointerHeld: false },
  ]);
  const kinds = effects.map((e) => e.kind);
  assert(kinds.includes("drag-pause"));
  assert(kinds.includes("drag-end"));
});

// ─────────────────────── F1 (paused-pan only emits pan-step on move) ──

Deno.test("F1: pointer-move while paused-pan emits only pan-step (no drag-move)", () => {
  const { state } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-empty",
      snapshot: snap({ clientX: 0, clientY: 0 }),
      ctx: gctx({ hit: dummyHit("stage-empty") }),
    },
    {
      kind: "pointer-move",
      snapshot: snap({ clientX: 50, clientY: 0 }),
      hit: dummyHit("stage-empty"),
    },
    { kind: "space-down" },
  ]);
  const r = pointerReducer(state, {
    kind: "pointer-move",
    snapshot: snap({ clientX: 60, clientY: 0 }),
    hit: dummyHit("stage-empty"),
  });
  assertEquals(r.effects.length, 1);
  assertEquals(r.effects[0]!.kind, "pan-step");
});

// ───────────────── Interruptions the reader actually finished ─────────

/**
 * A surface hears that the reader finished a gesture it could not see in three
 * ways: a pointermove carrying `buttons: 0`, a lost pointer capture, and a
 * `finished` end from the window watch in `gesture-router.ts`.
 * `hasSomethingToCommit` is the one rule all three ask, and these pin it per
 * state, because the answer differs by state and every one of them was previously
 * answered "cancel".
 *
 * It answers about the STATE only. Whether the reader finished the gesture at all
 * is the watch's `GestureEndReason`, pinned in `gesture-surface.test.ts`; a
 * `pointercancel` finishes nothing however promising the state looks.
 *
 * What the wrong answer looked like: a fast marquee selected nothing. The button
 * comes up mid-motion, a buttonless move reaches the window before the surface's
 * own pointerup, the watch reported an interruption, and the drag was cancelled
 * with its whole selection still only in the preview. Speed decided whether it
 * happened, so it read as random.
 *
 * The wiring from these to a real surface is browser-only — `use-surface-pointer`
 * is a hook, and Deno has no DOM — so what is checked here is the decision, and
 * the flick itself was measured in a browser: with one buttonless move ahead of
 * the release, a marquee over a peer went from selecting nothing to selecting the
 * same three entities a normal release does.
 *
 * Validated by injection: answering "pressed" instead of "dragging" fails both of
 * the first two. Answering a bare `false` — the old behavior — does not compile,
 * because the parameter goes unread, so it proves nothing and is not the check.
 */
Deno.test("a drag the reader finished out of sight has something to commit", () => {
  const { state } = dispatch(IDLE_MACHINE, [
    {
      kind: "pointer-down",
      surface: "stage-empty",
      snapshot: snap({ clientX: 100, clientY: 100 }),
      ctx: gctx({ hit: dummyHit("stage-empty") }),
    },
    {
      kind: "pointer-move",
      snapshot: snap({ clientX: 140, clientY: 140 }),
      hit: dummyHit("stage-empty"),
    },
  ]);
  assertEquals(state.fsm.kind, "dragging");
  assert(
    hasSomethingToCommit(state),
    "a drag in flight has something to commit and was thrown away",
  );
});

Deno.test("a press that never dragged has nothing to commit", () => {
  // Nothing is in flight to commit, and ending it would fire a click at wherever
  // the pointer was when the news arrived — which may be nowhere near what was
  // pressed, since this path is reached precisely when we missed the events in
  // between.
  const { state } = dispatch(IDLE_MACHINE, [{
    kind: "pointer-down",
    surface: "stage-peer",
    snapshot: snap(),
    ctx: gctx({ hit: dummyHit("stage-peer") }),
  }]);
  assertEquals(state.fsm.kind, "pressed");
  assertEquals(hasSomethingToCommit(state), false);
});

Deno.test("an idle machine has nothing to commit", () => {
  // The ordinary case, and why the rule is safe to ask on every path: a normal
  // release commits through the surface's own pointerup first, so the watch's
  // report lands here and does nothing.
  assertEquals(hasSomethingToCommit(IDLE_MACHINE), false);
});
