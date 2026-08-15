import { assert, assertEquals } from "@std/assert";
import { clickActionFor, drillInActionFor } from "./click-actions.ts";
import { dummyHit } from "./gesture-resolver.ts";
import { type EntityRef, type Hit, type ResolvedGesture, type SelectionDocSnapshot } from "./types.ts";

const EMPTY_DOC: SelectionDocSnapshot = {
  observations: [],
  duration: 0,
  entities: undefined,
};

function defaultVerb(hit: Hit): ResolvedGesture {
  // Tests construct DefaultVerb directly via the `tier: "default"`
  // wrapper. We don't go through the resolver — that's a separate
  // unit; clickActionFor is tested as a pure function on its input.
  switch (hit.surface) {
    case "stage-empty":
      return {
        tier: "default",
        verb: { kind: "rubber-band", mode: "replace" },
      };
    case "stage-peer":
      return {
        tier: "default",
        verb: {
          kind: "select-or-drag-peer",
          peerId: hit.peerId,
          entityRef: { kind: "peer", id: hit.peerId },
        },
      };
    case "timeline-ruler":
      return { tier: "default", verb: { kind: "scrub" } };
    case "timeline-overview":
      return { tier: "default", verb: { kind: "pan-view" } };
    case "timeline-lane-empty":
      return {
        tier: "default",
        verb: { kind: "rubber-band", mode: "replace" },
      };
    case "timeline-gutter-chevron":
      return {
        tier: "default",
        verb: { kind: "toggle-category", category: hit.category },
      };
    case "timeline-gutter-eyeball":
      return {
        tier: "default",
        verb: { kind: "toggle-row-visibility", scope: hit.scope },
      };
    case "timeline-gutter-label":
      return {
        tier: "default",
        verb: {
          kind: "reorder-row",
          category: hit.category,
          entityId: hit.entityId,
        },
      };
    case "timeline-lane-event-right-edge":
      return {
        tier: "default",
        verb: {
          kind: "drag-event-right-edge",
          eventId: hit.eventId,
          entityRef: hit.entityRef,
        },
      };
    case "timeline-gutter-edge":
      return { tier: "default", verb: { kind: "resize-gutter" } };
    case "timeline-overview-edge":
      return {
        tier: "default",
        verb: { kind: "resize-time-window", edge: hit.edge },
      };
    default:
      throw new Error(`unhandled in test fixture: ${hit.surface}`);
  }
}

// ─────────────────────── Selection mappings ───────────────────────────

Deno.test("rubber-band click on the stage → clear-on-empty-click 'stage'", () => {
  const r = clickActionFor(
    defaultVerb(dummyHit("stage-empty")),
    dummyHit("stage-empty"),
    EMPTY_DOC,
  );
  assert(r);
  assertEquals(r.kind, "selection");
  if (r.kind === "selection" && r.action.kind === "clear-on-empty-click") {
    assertEquals(r.action.surface, "stage");
  } else {
    throw new Error(`expected clear-on-empty-click, got ${JSON.stringify(r)}`);
  }
});

Deno.test("select-or-drag-peer click → selection: set-selection [peer]", () => {
  const hit = dummyHit("stage-peer", { peerId: "alice" });
  const r = clickActionFor(defaultVerb(hit), hit, EMPTY_DOC);
  assert(r);
  assertEquals(r.kind, "selection");
  if (r.kind === "selection" && r.action.kind === "set-selection") {
    assertEquals(r.action.entities.size, 1);
    assert(r.action.entities.has("peer:alice"));
  }
});

// One verb, two surfaces: the marquee's click clears, and the hit decides
// whose empty-space rules it clears by. The Scrubber's press on an empty lane
// starts this marquee, and its no-sweep release clears the timeline's way —
// the time range goes with the selection.
Deno.test("rubber-band click in a lane → clear-on-empty-click 'timeline'", () => {
  const hit = dummyHit("timeline-lane-empty", { t: 1000 });
  const r = clickActionFor(defaultVerb(hit), hit, EMPTY_DOC);
  assert(r);
  assertEquals(r.kind, "selection");
  if (r.kind === "selection" && r.action.kind === "clear-on-empty-click") {
    assertEquals(r.action.surface, "timeline");
  } else {
    throw new Error(`expected clear-on-empty-click, got ${JSON.stringify(r)}`);
  }
});

// ─────────────────────── View / engine mappings ───────────────────────

Deno.test("scrub click on ruler → seek to t", () => {
  const hit = dummyHit("timeline-ruler", { t: 1500 });
  const r = clickActionFor(defaultVerb(hit), hit, EMPTY_DOC);
  assert(r);
  if (r.kind === "seek") assertEquals(r.t, 1500);
});

Deno.test("pan-view click on overview → jump-window-center to t", () => {
  const hit = dummyHit("timeline-overview", { t: 2500 });
  const r = clickActionFor(defaultVerb(hit), hit, EMPTY_DOC);
  assert(r);
  if (r.kind === "jump-window-center") assertEquals(r.t, 2500);
});

Deno.test("toggle-category click → toggle-category action", () => {
  const hit = dummyHit("timeline-gutter-chevron", { category: "sessions" });
  const r = clickActionFor(defaultVerb(hit), hit, EMPTY_DOC);
  assert(r);
  if (r.kind === "toggle-category") assertEquals(r.category, "sessions");
});

Deno.test("toggle-row-visibility click → the action carries the eyeball's scope", () => {
  const hit = dummyHit("timeline-gutter-eyeball", {
    category: "peers",
    entityId: "alice",
  });
  const r = clickActionFor(defaultVerb(hit), hit, EMPTY_DOC);
  assert(r);
  if (r.kind === "toggle-row-visibility") {
    assertEquals(r.scope, {
      kind: "row",
      category: "peers",
      entityId: "alice",
    });
  }
});

Deno.test("a category eyeball and the all-rows eyeball carry their own scope", () => {
  // One control repeated down one column, so one surface: the click acts on
  // the rows the scope names, and nothing else about it changes.
  for (
    const scope of [
      { kind: "category", category: "sessions" },
      { kind: "all" },
    ] as const
  ) {
    const hit: Hit = { surface: "timeline-gutter-eyeball", scope };
    const r = clickActionFor(defaultVerb(hit), hit, EMPTY_DOC);
    assert(r);
    assertEquals(r.kind, "toggle-row-visibility");
    if (r.kind === "toggle-row-visibility") assertEquals(r.scope, scope);
  }
});

// ─────────────────────── Null mappings (drag-only handles) ────────────

Deno.test("the gutter seam and an overview grip click → null (drag-only)", () => {
  for (
    const hit of [
      dummyHit("timeline-gutter-edge"),
      dummyHit("timeline-overview-edge"),
    ]
  ) {
    assertEquals(clickActionFor(defaultVerb(hit), hit, EMPTY_DOC), null);
  }
});

Deno.test("drag-event-right-edge click → null (drag-only)", () => {
  const hit = dummyHit("timeline-lane-event-right-edge");
  assertEquals(clickActionFor(defaultVerb(hit), hit, EMPTY_DOC), null);
});

Deno.test("reorder-row click → null (drag-only)", () => {
  const hit = dummyHit("timeline-gutter-label");
  assertEquals(clickActionFor(defaultVerb(hit), hit, EMPTY_DOC), null);
});

// ─────────────────────── Tier-bypassing verbs ─────────────────────────

Deno.test("space-pan click → null (FSM shouldn't emit this; defensive)", () => {
  const verb: ResolvedGesture = {
    tier: "space-pan",
    verb: { kind: "pan-surface" },
  };
  assertEquals(
    clickActionFor(verb, dummyHit("stage-empty"), EMPTY_DOC),
    null,
  );
});

Deno.test("hand-tool click → null", () => {
  const verb: ResolvedGesture = {
    tier: "hand-tool",
    verb: { kind: "pan-surface" },
  };
  assertEquals(
    clickActionFor(verb, dummyHit("stage-peer"), EMPTY_DOC),
    null,
  );
});

Deno.test("tool-create click → null (host handles directly)", () => {
  const verb: ResolvedGesture = {
    tier: "tool-create",
    verb: { kind: "create-peer-at", t: 0 },
  };
  assertEquals(
    clickActionFor(verb, dummyHit("stage-empty"), EMPTY_DOC),
    null,
  );
});

// ─────────────────────── Modifier-augmented verbs ─────────────────────

Deno.test("toggle-in-selection click → selection: toggle-in-selection", () => {
  const entity: EntityRef = { kind: "peer", id: "carol" };
  const r = clickActionFor(
    {
      tier: "modifier",
      modifier: "cmd",
      verb: { kind: "toggle-in-selection", entity },
    },
    dummyHit("stage-peer", { peerId: "carol" }),
    EMPTY_DOC,
  );
  assert(r);
  if (r.kind === "selection" && r.action.kind === "toggle-in-selection") {
    assertEquals(r.action.entity.id, "carol");
  }
});

Deno.test("extend-selection-range click → selection: extend-selection-range with doc", () => {
  const toEntity: EntityRef = { kind: "peer", id: "dave" };
  const doc: SelectionDocSnapshot = {
    observations: [{ id: "e", t: 0, kind: "peer-joined" }],
    duration: 100,
    entities: { peers: { dave: {} } },
  };
  const r = clickActionFor(
    {
      tier: "modifier",
      modifier: "shift",
      verb: { kind: "extend-selection-range", toEntity },
    },
    dummyHit("stage-peer", { peerId: "dave" }),
    doc,
  );
  assert(r);
  if (r.kind === "selection" && r.action.kind === "extend-selection-range") {
    assertEquals(r.action.toEntity.id, "dave");
    assertEquals(r.action.doc.duration, 100);
  }
});

// ─────────────────────── drill-in helper ──────────────────────────────

Deno.test("drillInActionFor wraps entity in drill-in action", () => {
  const entity: EntityRef = { kind: "session", id: "s7" };
  const r = drillInActionFor(entity);
  assertEquals(r.kind, "drill-in");
  if (r.kind === "drill-in") assertEquals(r.entity.id, "s7");
});
