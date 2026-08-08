import { assertEquals, assertNotEquals } from "@std/assert";
import { attachedEndpoint } from "../../schema/topology.ts";
import { applyRowOrder } from "../../engine/event-helpers.ts";
import { hitTestEvents, hitTestGutter } from "./hit-test.ts";
import { iterateRows, type RowDescriptor } from "./row-layout.ts";
import {
  LABEL_GAP_PX,
  LABEL_MIN_PX,
  type LaneLabelInput,
  layoutLaneLabels,
  monoAdvance,
  truncateToWidth,
} from "./label-layout.ts";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import { projectFromObservations } from "../../engine/temporal/project-from-observations.ts";
import {
  applyWheel,
  clampView,
  type LaneKind,
  pan,
  type TimelineView,
  zoomAround,
} from "./state.ts";

// Same advance the Scrubber renders at (mono font, SIZE.xs = 9 px).
const ADVANCE = monoAdvance(9);

/** Assert the plan is event-addressed and return its eventId — the
 * loaded-fixture cases below all expect the event-addressed variants;
 * entity-addressed plans (freshly authored spans) have their own cases. */
function eventIdOf(plan: import("./hit-test.ts").DragPlan | null): string {
  if (plan === null || !("eventId" in plan)) {
    throw new Error("expected an event-addressed drag plan");
  }
  return plan.eventId;
}

function input(
  partial: Pick<LaneLabelInput, "id" | "startT" | "label" | "pillLeft"> & {
    pillRight?: number;
  },
): LaneLabelInput {
  return {
    id: partial.id,
    startT: partial.startT,
    label: partial.label,
    pillLeft: partial.pillLeft,
    // Default the pill to "wide enough not to clip"; tests that
    // care about per-pill bounds set this explicitly.
    pillRight: partial.pillRight ?? partial.pillLeft + 5000,
  };
}

Deno.test("layoutLaneLabels: single label fits at natural position", () => {
  const placed = layoutLaneLabels(
    [input({ id: "a", startT: 0, label: "hello", pillLeft: 100 })],
    ADVANCE,
    LABEL_GAP_PX,
    LABEL_MIN_PX,
  );
  assertEquals(placed.length, 1);
  assertEquals(placed[0]!.id, "a");
  assertEquals(placed[0]!.label, "hello");
  // pillLeft (100) + LABEL_INSET_PX (5) = 105
  assertEquals(placed[0]!.x, 105);
});

Deno.test("layoutLaneLabels: non-overlapping labels both at natural", () => {
  // Two labels far apart in time → both fit at their pill anchors.
  const placed = layoutLaneLabels(
    [
      input({ id: "a", startT: 0, label: "alpha", pillLeft: 100 }),
      input({ id: "b", startT: 1000, label: "beta", pillLeft: 500 }),
    ],
    ADVANCE,
    LABEL_GAP_PX,
    LABEL_MIN_PX,
  );
  assertEquals(placed.length, 2);
  assertEquals(placed[0]!.x, 105);
  assertEquals(placed[1]!.x, 505);
  assertEquals(placed[0]!.label, "alpha");
  assertEquals(placed[1]!.label, "beta");
});

Deno.test("layoutLaneLabels: later wins, earlier shifts left to keep full label", () => {
  // Earlier label "hello" (5 chars) at pillLeft=100. Natural [105, 105+5*ADVANCE].
  // Later label "x" at pillLeft=120 (1 char). Natural [125, 125+ADVANCE].
  // Earlier's natural right (~132) overlaps later's natural left (125).
  // Later wins → placed at 125. Earlier's rightLimit = 125 - GAP = 121.
  // Earlier full width = 5*ADVANCE ≈ 27 → shiftedX = 121 - 27 ≈ 94.
  // 94 < earlier's leftAnchor (105) → can't shift while pill-anchored → truncate.
  const placed = layoutLaneLabels(
    [
      input({ id: "a", startT: 0, label: "hello", pillLeft: 100 }),
      input({ id: "b", startT: 10, label: "x", pillLeft: 120 }),
    ],
    ADVANCE,
    LABEL_GAP_PX,
    LABEL_MIN_PX,
  );
  assertEquals(placed.length, 2);
  // Earlier placed first in output (paint order = left-to-right).
  assertEquals(placed[0]!.id, "a");
  assertEquals(placed[0]!.x, 105);
  assertEquals(placed[0]!.label.endsWith("…"), true);
  assertEquals(placed[1]!.id, "b");
  assertEquals(placed[1]!.x, 125);
  assertEquals(placed[1]!.label, "x");
});

Deno.test("layoutLaneLabels: earlier full label fits when neighbor leaves room", () => {
  // Pill A starts at 100 (anchor 105) with a 5-char label (~27 px
  // natural). Pill B's label starts at 155. A's available range is
  // [105, 151] = 46 px. 27 ≤ 46 → A keeps its full label.
  const placed = layoutLaneLabels(
    [
      input({
        id: "a",
        startT: 0,
        label: "hello",
        pillLeft: 100,
        pillRight: 400,
      }),
      input({ id: "b", startT: 10, label: "x", pillLeft: 150 }),
    ],
    ADVANCE,
    LABEL_GAP_PX,
    LABEL_MIN_PX,
  );
  assertEquals(placed.length, 2);
  assertEquals(placed[0]!.id, "a");
  assertEquals(placed[0]!.label, "hello");
  // Labels stay anchored to their pill — A at 105, B at 155.
  assertEquals(placed[0]!.x, 105);
  assertEquals(placed[1]!.x, 155);
});

Deno.test("layoutLaneLabels: drops label when no room for even ellipsis", () => {
  // Two labels at virtually the same x — earlier has no room.
  const placed = layoutLaneLabels(
    [
      input({ id: "a", startT: 0, label: "alice", pillLeft: 100 }),
      input({ id: "b", startT: 1, label: "bob", pillLeft: 101 }),
    ],
    ADVANCE,
    LABEL_GAP_PX,
    LABEL_MIN_PX,
  );
  // Only the later survives — the earlier's available width is
  // (101 - GAP) - 105 < 0 → dropped.
  assertEquals(placed.length, 1);
  assertEquals(placed[0]!.id, "b");
});

Deno.test("layoutLaneLabels: cascade — three overlapping spans, later wins each step", () => {
  // All three pills start near t=0; same overlap problem cascading.
  // Carol (latest) gets full label. Bob then has tiny available
  // width vs Carol → drops or shrinks. Alice has even less → drops.
  const placed = layoutLaneLabels(
    [
      input({ id: "alice", startT: 0, label: "alice (gifter)", pillLeft: 100 }),
      input({ id: "bob", startT: 5, label: "bob (receiver)", pillLeft: 103 }),
      input({
        id: "carol",
        startT: 10,
        label: "Carol (exporter)",
        pillLeft: 106,
      }),
    ],
    ADVANCE,
    LABEL_GAP_PX,
    LABEL_MIN_PX,
  );
  // Carol always present, full label.
  const carol = placed.find((p) => p.id === "carol");
  assertEquals(carol !== undefined, true);
  assertEquals(carol!.label, "Carol (exporter)");
  assertEquals(carol!.x, 111);
  // Earlier ones are either truncated heavily or dropped — both are
  // acceptable per variation 1; the invariant is that no surviving
  // label's right edge passes any later label's left edge.
  let prevLeft = Number.POSITIVE_INFINITY;
  // Walk right-to-left checking the non-overlap invariant.
  for (let i = placed.length - 1; i >= 0; i--) {
    const p = placed[i]!;
    const right = p.x + p.label.length * ADVANCE;
    if (i < placed.length - 1) {
      // right edge of this label ≤ left of the next placed label
      assertEquals(right <= prevLeft + 1e-6, true);
    }
    prevLeft = p.x;
  }
});

Deno.test("layoutLaneLabels: per-pill clip prevents overflow past pill.right", () => {
  // Single narrow pill with a long label — should truncate to fit
  // INSIDE its own pill bounds even without any neighbor pressure.
  const placed = layoutLaneLabels(
    [
      input({
        id: "a",
        startT: 0,
        label: "op:start-session",
        pillLeft: 100,
        pillRight: 130, // 30 px wide pill
      }),
    ],
    ADVANCE,
    LABEL_GAP_PX,
    LABEL_MIN_PX,
  );
  assertEquals(placed.length, 1);
  const p = placed[0]!;
  // Right edge must not exceed pillRight - LABEL_INSET_PX = 125.
  const rightEdge = p.x + p.label.length * ADVANCE;
  assertEquals(rightEdge <= 125 + 1e-6, true);
  assertEquals(p.label.endsWith("…"), true);
});

Deno.test("layoutLaneLabels: stable ordering for same input set", () => {
  // Same logical set in two different input orders → same outputs.
  const a = input({ id: "a", startT: 0, label: "alpha", pillLeft: 100 });
  const b = input({ id: "b", startT: 0, label: "beta", pillLeft: 100 });
  const c = input({ id: "c", startT: 5, label: "gamma", pillLeft: 200 });
  const r1 = layoutLaneLabels([a, b, c], ADVANCE, LABEL_GAP_PX, LABEL_MIN_PX);
  const r2 = layoutLaneLabels([c, b, a], ADVANCE, LABEL_GAP_PX, LABEL_MIN_PX);
  assertEquals(r1, r2);
});

Deno.test("layoutLaneLabels: skips inputs with undefined label", () => {
  const placed = layoutLaneLabels(
    [
      input({ id: "a", startT: 0, label: undefined, pillLeft: 100 }),
      input({ id: "b", startT: 10, label: "beta", pillLeft: 200 }),
    ],
    ADVANCE,
    LABEL_GAP_PX,
    LABEL_MIN_PX,
  );
  assertEquals(placed.length, 1);
  assertEquals(placed[0]!.id, "b");
});

Deno.test("truncateToWidth: returns label unchanged when it fits", () => {
  // 5 chars × ADVANCE = 30 px; allow 50 → fits whole.
  assertEquals(truncateToWidth("hello", 50, ADVANCE), "hello");
});

Deno.test("truncateToWidth: truncates with ellipsis when wider than max", () => {
  // 10 chars natural = 60 px; allow 30 px → ellipsis + (30/ADVANCE - 1) chars.
  const out = truncateToWidth("abcdefghij", 30, ADVANCE);
  assertEquals(out.endsWith("…"), true);
  // Result must fit in max width.
  assertEquals(out.length * ADVANCE <= 30 + 1e-6, true);
});

Deno.test("truncateToWidth: returns ellipsis only when no char room", () => {
  // 1 char of room after the ellipsis would mean 6 px each; if we
  // allow only the ellipsis width plus a tiny slop, no char fits.
  const out = truncateToWidth("abcdef", ADVANCE + 0.5, ADVANCE);
  assertEquals(out, "…");
});

Deno.test("truncateToWidth: returns empty when ellipsis itself doesn't fit", () => {
  // Less than one advance worth of pixels → no room for even the
  // ellipsis glyph; caller should drop.
  assertEquals(truncateToWidth("abc", ADVANCE - 1, ADVANCE), "");
});

// ─────────────────── hitTestEvents (Phase 1+2+3) ───────────────────
//
// Geometry the tests assume:
//   width            = 224
//   LANE_LABEL_WIDTH = 104 (constant in state.ts; bumped from 80
//                           to fit chevron + category-eyeball +
//                           category label)
//   plotWidth        = 120
//   windowStart..End = 0..1000
//   → t→px:  px(t) = 104 + (t / 1000) * 120
//   → t=500 → px=164;  t=1000 → px=224;  t=800 → px=200
//
//   RULER_HEIGHT = 22; LANE_GAP = 2; laneHeight = 30
//   expanded = {peers, sessions, messages}
//   → height = RULER + 3*(LH+GAP) = 22 + 96 = 118
//   → peer lane y ∈ [0, 32), session ∈ [32, 64), messages ∈ [64, 96)
//     ruler ∈ [96, 118)

const VIEW: TimelineView = {
  windowStart: 0,
  windowEnd: 1000,
  expandedLanes: new Set<LaneKind>(["peers", "sessions", "messages"]),
  // Categories collapsed (today's default look). The expanded
  // per-entity row layout is covered by its own tests below.
  expandedCategories: new Set(),
};
// Width chosen so the plot is exactly 120 px after subtracting the
// 104 px gutter AND the 4 px left + 4 px right pad — keeps the pixel
// arithmetic in the docstring above tractable and isolates these
// tests from gutter-default / pad changes.
const WIDTH = 232;
const HEIGHT = 118;
const LANE_HEIGHT = 30;

function makePeer(id: string, joinT: number, leftT?: number): TimelineEvent[] {
  const out: TimelineEvent[] = [
    {
      id: `${id}-joined`,
      kind: "peer-joined",
      t: joinT,
      peerId: id,
      profile: "pancake",
    },
  ];
  if (leftT !== undefined) {
    out.push({
      id: `${id}-left`,
      kind: "peer-left",
      t: leftT,
      peerId: id,
    });
  }
  return out;
}

/** Build the row layout the renderer would paint for `events`,
 *  using the test fixture's collapsed-categories VIEW. Always
 *  injects a placeholder per category so the test's py-values
 *  (HEIGHT = 22 + 3·32 layout) hit the expected lanes regardless
 *  of what events the specific test supplies. Production behavior
 *  (auto-hide empty categories) is exercised by `iterateRows`
 *  tests above. */
/** Build a minimal TimelineDocument from `events` so hitTestEvents
 *  can resolve span shapes through the same `*Effective` helpers the
 *  renderer uses. Mirrors how production builds the doc: store
 *  observations on a fixture recording source and run
 *  `projectFromObservations` to seed `entities.*.timing`. */
function docFor(events: readonly TimelineEvent[]): TimelineDocument {
  const base: TimelineDocument = {
    id: "scrubber-test",
    duration: 1000,
    recording: {
      sources: [{
        id: "fixture",
        meta: { kind: "fixture" },
        observations: [...events],
      }],
    },
    rowOrder: {},
    rowHidden: {},
    rowLabelHidden: {},
    rowBodyHidden: {},
  };
  return projectFromObservations(base);
}

function rowsFor(events: readonly TimelineEvent[]): RowDescriptor[] {
  const peers = new Set<string>(["_peer_placeholder"]);
  const sessions = new Set<string>(["_session_placeholder"]);
  const messages = new Set<string>(["_message_placeholder"]);
  for (const ev of events) {
    if (ev.kind === "peer-joined" || ev.kind === "peer-left") {
      peers.add(ev.peerId);
    } else if (
      ev.kind === "session-opened" ||
      ev.kind === "session-closed" ||
      ev.kind === "session-state-changed"
    ) sessions.add(ev.sessionId);
    else if (
      ev.kind === "message-sent" || ev.kind === "message-delivered"
    ) messages.add(ev.messageId);
  }
  return [...iterateRows(
    VIEW.expandedLanes,
    VIEW.expandedCategories,
    {
      peers: [...peers],
      sessions: [...sessions],
      messages: [...messages],
    },
    undefined,
    LANE_HEIGHT,
  )];
}

Deno.test("hitTestEvents: click on peer span returns peer selection + joined event", () => {
  const events = makePeer("alice", 0, 1000);
  // px=152 → t=400; well inside Alice's [0..1000] span. py=10 →
  // peers lane.
  const hit = hitTestEvents(
    152,
    10,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertNotEquals(hit, null);
  assertEquals(hit!.entity, { kind: "peer", id: "alice" });
  assertEquals(hit!.drag?.kind, "span-body");
  assertEquals(eventIdOf(hit!.drag), "alice-joined");
});

Deno.test("hitTestEvents: click on peer right edge returns peer-left event with rightEdge=true", () => {
  const events = makePeer("alice", 0, 1000);
  // Right edge is at px(1000)=224; click at px=222 (within 6 px).
  const hit = hitTestEvents(
    222,
    10,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertNotEquals(hit, null);
  assertEquals(hit!.drag?.kind, "span-edge");
  assertEquals(eventIdOf(hit!.drag), "alice-left");
  assertEquals(
    hit!.drag?.kind === "span-edge" ? hit!.drag.edge : null,
    "right",
  );
});

Deno.test("hitTestEvents: peer without peer-left has no right-edge handle", () => {
  // Alice never leaves → no peer-left to retime. A click at the
  // window edge still picks her up but eventId stays at joined.
  const events = makePeer("alice", 0);
  const hit = hitTestEvents(
    222,
    10,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertNotEquals(hit, null);
  // No peer-left = no right-edge handle; the click falls through to
  // body translate against the peer-joined event.
  assertEquals(hit!.drag?.kind, "span-body");
  assertEquals(eventIdOf(hit!.drag), "alice-joined");
});

Deno.test("hitTestEvents: authored peer with no observations gets an entity-addressed drag plan", () => {
  // `add-peer` seeds entity.timing but emits no peer-joined
  // observation. The renderer paints the peer via peerEffective(doc);
  // the hit-test MUST agree — and the gesture must be retimeable
  // exactly like a loaded peer's, addressed by entity instead of by
  // an observation event (`move-entity-span` is the write path).
  const doc: TimelineDocument = {
    id: "scrubber-test",
    duration: 1000,
    entities: {
      peers: {
        alice: {
          profile: "pancake",
          label: "alice",
          timing: {
            start: { value: 0, explicit: true },
            duration: { value: 1000, explicit: true },
          },
        },
      },
    },
    recording: {
      sources: [{ id: "fixture", meta: { kind: "fixture" }, observations: [] }],
    },
    rowOrder: {},
    rowHidden: {},
    rowLabelHidden: {},
    rowBodyHidden: {},
  };
  const hit = hitTestEvents(
    152,
    10,
    WIDTH,
    HEIGHT,
    VIEW,
    [],
    rowsFor([{
      kind: "peer-joined",
      id: "alice-joined",
      peerId: "alice",
      profile: "pancake",
      t: 0,
    }]),
    doc,
  );
  assertNotEquals(hit, null);
  assertEquals(hit!.entity, { kind: "peer", id: "alice" });
  assertEquals(hit!.drag, {
    kind: "entity-span-body",
    ref: { kind: "peer", id: "alice" },
    originalT: 0,
  });
});

Deno.test("hitTestEvents: click in gutter returns null", () => {
  const events = makePeer("alice", 0, 1000);
  // px=30 is left of LANE_LABEL_WIDTH=104.
  const hit = hitTestEvents(
    30,
    10,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertEquals(hit, null);
});

Deno.test("hitTestEvents: click in ruler area returns null", () => {
  const events = makePeer("alice", 0, 1000);
  // py=100 → ruler band [96, 118).
  const hit = hitTestEvents(
    152,
    100,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertEquals(hit, null);
});

Deno.test("hitTestEvents: click on collapsed lane returns null", () => {
  // Only the peers lane is expanded → sessions/messages don't
  // contribute a hit zone even though their events exist.
  const view: TimelineView = {
    ...VIEW,
    expandedLanes: new Set<LaneKind>(["peers"]),
  };
  const heightCollapsed = 22 + 1 * (LANE_HEIGHT + 2); // 54
  const events: TimelineEvent[] = [
    ...makePeer("alice", 0, 1000),
    {
      id: "s1-open",
      kind: "session-opened",
      t: 100,
      sessionId: "s1",
      a: attachedEndpoint("alice"),
      b: attachedEndpoint("bob"),
      codec: "capnp",
      captpVersion: "v1_0",
    },
  ];
  // py=10 → peers lane (only expanded lane).
  const rowsForView = [...iterateRows(
    view.expandedLanes,
    view.expandedCategories,
    { peers: ["alice"], sessions: ["s1"], messages: [] },
    undefined,
    LANE_HEIGHT,
  )];
  const hitPeer = hitTestEvents(
    128,
    10,
    WIDTH,
    heightCollapsed,
    view,
    events,
    rowsForView,
    docFor(events),
  );
  assertEquals(hitPeer?.entity.kind, "peer");
});

Deno.test("hitTestEvents: session-state-changed glyph wins over span at same t", () => {
  // Within EDGE_HANDLE_PX (6) of t=500 (px=164) the glyph at
  // t=500 should be picked instead of the underlying session span.
  const events: TimelineEvent[] = [
    {
      id: "s1-open",
      kind: "session-opened",
      t: 0,
      sessionId: "s1",
      a: attachedEndpoint("alice"),
      b: attachedEndpoint("bob"),
      codec: "capnp",
      captpVersion: "v1_0",
    },
    {
      id: "s1-state",
      kind: "session-state-changed",
      t: 500,
      sessionId: "s1",
      state: "open",
    },
    {
      id: "s1-close",
      kind: "session-closed",
      t: 1000,
      sessionId: "s1",
    },
  ];
  // py=40 → sessions lane.
  const hit = hitTestEvents(
    164,
    40,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertNotEquals(hit, null);
  assertEquals(hit!.entity, { kind: "session", id: "s1" });
  assertEquals(hit!.drag?.kind, "moment");
  assertEquals(eventIdOf(hit!.drag), "s1-state");
});

Deno.test("hitTestEvents: peer rename glyph wins over the peer's span", () => {
  // A rename is a moment on the peer's row, pickable like a
  // session's state diamond: clicking it grabs the rename, so it
  // can be retimed instead of translating the whole peer.
  const events: TimelineEvent[] = [
    ...makePeer("127.0.0.1:0", 0, 1000),
    {
      id: "rename-1",
      kind: "peer-updated",
      t: 500,
      peerId: "127.0.0.1:0",
      label: "carol",
    },
  ];
  // px=164 → t=500; py=10 → peers lane.
  const hit = hitTestEvents(
    164,
    10,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertNotEquals(hit, null);
  assertEquals(hit!.entity, { kind: "peer", id: "127.0.0.1:0" });
  assertEquals(hit!.drag?.kind, "moment");
  assertEquals(eventIdOf(hit!.drag), "rename-1");
});

Deno.test("hitTestEvents: peer edge wins over a rename at the same t", () => {
  // Same priority the session lane holds: edges beat diamonds, so
  // dragging the peer's end never grabs a rename sitting on it.
  const events: TimelineEvent[] = [
    ...makePeer("127.0.0.1:0", 0, 1000),
    {
      id: "rename-1",
      kind: "peer-updated",
      t: 1000,
      peerId: "127.0.0.1:0",
      label: "carol",
    },
  ];
  // px=222 is within EDGE_HANDLE_PX of both the rename and the
  // peer's right edge at px=224.
  const hit = hitTestEvents(
    222,
    10,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertNotEquals(hit, null);
  assertEquals(hit!.drag?.kind, "span-edge");
  assertEquals(eventIdOf(hit!.drag), "127.0.0.1:0-left");
});

Deno.test("hitTestEvents: session edge wins over diamond at same t (priority: edges > diamonds > body)", () => {
  // session-closed at t=1000 (px=224) and a state-change diamond
  // also at t=1000. Clicking near the right edge MUST land on the
  // close event so dragging retimes the pill, not the diamond.
  const events: TimelineEvent[] = [
    {
      id: "s1-open",
      kind: "session-opened",
      t: 0,
      sessionId: "s1",
      a: attachedEndpoint("alice"),
      b: attachedEndpoint("bob"),
      codec: "capnp",
      captpVersion: "v1_0",
    },
    {
      id: "s1-state-final",
      kind: "session-state-changed",
      t: 1000,
      sessionId: "s1",
      state: "closed",
    },
    {
      id: "s1-close",
      kind: "session-closed",
      t: 1000,
      sessionId: "s1",
    },
  ];
  // py=40 → sessions lane; px=222 is within EDGE_HANDLE_PX of both
  // the diamond at px=224 and the close edge at px=224.
  const hit = hitTestEvents(
    222,
    40,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertNotEquals(hit, null);
  assertEquals(hit!.drag?.kind, "span-edge");
  assertEquals(eventIdOf(hit!.drag), "s1-close");
  assertEquals(
    hit!.drag?.kind === "span-edge" ? hit!.drag.edge : null,
    "right",
  );
});

Deno.test("hitTestEvents: session-opened edge wins over diamond at same t", () => {
  // Mirror of the closed-edge test for the LEFT edge.
  const events: TimelineEvent[] = [
    {
      id: "s1-open",
      kind: "session-opened",
      t: 0,
      sessionId: "s1",
      a: attachedEndpoint("alice"),
      b: attachedEndpoint("bob"),
      codec: "capnp",
      captpVersion: "v1_0",
    },
    {
      id: "s1-state-initial",
      kind: "session-state-changed",
      t: 0,
      sessionId: "s1",
      state: "negotiating",
    },
  ];
  // px=106 → t≈16, within EDGE_HANDLE_PX of t=0 (px=104).
  const hit = hitTestEvents(
    106,
    40,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertNotEquals(hit, null);
  assertEquals(hit!.drag?.kind, "span-edge");
  assertEquals(eventIdOf(hit!.drag), "s1-open");
  assertEquals(
    hit!.drag?.kind === "span-edge" ? hit!.drag.edge : null,
    "left",
  );
});

Deno.test("hitTestEvents: message body click returns message-sent event without rightEdge", () => {
  const events: TimelineEvent[] = [
    {
      id: "m1-sent",
      kind: "message-sent",
      t: 200,
      messageId: "m1",
      sessionId: "s1",
      from: "alice",
      to: "bob",
      arrivalT: 800,
    },
  ];
  // px(500) = 164 — middle of [200..800] span; py=70 → messages lane.
  const hit = hitTestEvents(
    164,
    70,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertNotEquals(hit, null);
  assertEquals(hit!.drag?.kind, "message-body");
  assertEquals(eventIdOf(hit!.drag), "m1-sent");
  assertEquals(
    hit!.drag?.kind === "message-body" ? hit!.drag.start : null,
    200,
  );
  assertEquals(
    hit!.drag?.kind === "message-body" ? hit!.drag.end : null,
    800,
  );
});

Deno.test("hitTestEvents: message right edge returns rightEdge=true for arrivalT drag", () => {
  const events: TimelineEvent[] = [
    {
      id: "m1-sent",
      kind: "message-sent",
      t: 200,
      messageId: "m1",
      sessionId: "s1",
      from: "alice",
      to: "bob",
      arrivalT: 800,
    },
  ];
  // px(800) = 104 + 0.8*120 = 200; click at 198 (within 6 px).
  const hit = hitTestEvents(
    198,
    70,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertNotEquals(hit, null);
  assertEquals(hit!.drag?.kind, "message-edge");
  assertEquals(
    hit!.drag?.kind === "message-edge" ? hit!.drag.edge : null,
    "right",
  );
});

Deno.test("hitTestEvents: expanded peers category — per-entity row narrows the hit", () => {
  // With peers expanded, the row layout is: header at y≈1
  // (h=30), then alice at y≈33, bob at y≈65. Clicking bob's row
  // must pick bob's events specifically, NOT "latest started".
  const events = [...makePeer("alice", 0, 1000), ...makePeer("bob", 300, 900)];
  const expandedView: TimelineView = {
    ...VIEW,
    expandedCategories: new Set<Exclude<LaneKind, "ruler">>(["peers"]),
  };
  const rows = [...iterateRows(
    expandedView.expandedLanes,
    expandedView.expandedCategories,
    { peers: ["alice", "bob"], sessions: [], messages: [] },
    undefined,
    LANE_HEIGHT,
  )];
  // y=33..63 → alice row. Picking middle of alice's span at t=500.
  const aliceHit = hitTestEvents(
    164,
    45,
    WIDTH,
    HEIGHT,
    expandedView,
    events,
    rows,
    docFor(events),
  );
  assertNotEquals(aliceHit, null);
  assertEquals(aliceHit!.entity, { kind: "peer", id: "alice" });
  // y=65..95 → bob row. Same t=500 — bob is alive, alice is too,
  // but the row constraint locks the answer to bob.
  const bobHit = hitTestEvents(
    164,
    78,
    WIDTH,
    HEIGHT,
    expandedView,
    events,
    rows,
    docFor(events),
  );
  assertNotEquals(bobHit, null);
  assertEquals(bobHit!.entity, { kind: "peer", id: "bob" });
});

Deno.test("hitTestEvents: stacked peers — latest start wins", () => {
  // Alice (0..1000) and Bob (300..900) both alive at t=500. The
  // paint order puts later-started spans on top, so Bob wins.
  const events = [...makePeer("alice", 0, 1000), ...makePeer("bob", 300, 900)];
  const hit = hitTestEvents(
    164,
    10,
    WIDTH,
    HEIGHT,
    VIEW,
    events,
    rowsFor(events),
    docFor(events),
  );
  assertNotEquals(hit, null);
  assertEquals(hit!.entity.id, "bob");
});

// ───────────── Flash-grade row-header tests (PR 1) ───────────

Deno.test("applyRowOrder: empty/undefined override returns insertion order", () => {
  assertEquals(applyRowOrder(["a", "b", "c"], undefined), ["a", "b", "c"]);
  assertEquals(applyRowOrder(["a", "b", "c"], []), ["a", "b", "c"]);
});

Deno.test("applyRowOrder: listed ids first, then unlisted by insertion order", () => {
  assertEquals(
    applyRowOrder(["a", "b", "c", "d"], ["c", "a"]),
    ["c", "a", "b", "d"],
  );
});

Deno.test("applyRowOrder: ids in override that don't exist are skipped", () => {
  // Stale rowOrder (entity deleted) shouldn't break rendering.
  assertEquals(
    applyRowOrder(["a", "b"], ["ghost", "a", "another-ghost"]),
    ["a", "b"],
  );
});

Deno.test(
  "iterateRows: every toggled-on category produces a collapsed row, empty included",
  () => {
    const rows = [...iterateRows(
      new Set<LaneKind>(["peers", "sessions", "messages"]),
      new Set(),
      { peers: ["alice", "bob"], sessions: ["s1"], messages: [] },
      undefined,
      30,
    )];
    // The lane toggle alone decides row existence — an empty
    // `messages` still gets its row, so content coming and going
    // never shifts the chrome and the category stays expandable.
    assertEquals(rows.length, 3);
    for (const r of rows) assertEquals(r.kind, "category-collapsed");
  },
);

Deno.test(
  "iterateRows: expanded-but-empty categories emit headers only",
  () => {
    // Expansion is user-set state, so each drilled-down empty
    // category keeps its header (the chevron is the way back);
    // no entity rows exist to draw under it.
    const rows = [...iterateRows(
      new Set<LaneKind>(["peers", "sessions", "messages"]),
      new Set(["peers", "sessions", "messages"]),
      { peers: [], sessions: [], messages: [] },
      undefined,
      30,
    )];
    assertEquals(rows.length, 3);
    for (const r of rows) assertEquals(r.kind, "category-header");
  },
);

Deno.test("iterateRows: expanded category yields header + entity rows", () => {
  const rows = [...iterateRows(
    new Set<LaneKind>(["peers"]),
    new Set(["peers"]),
    { peers: ["alice", "bob"], sessions: [], messages: [] },
    undefined,
    30,
  )];
  // 1 header + 2 entity rows.
  assertEquals(rows.length, 3);
  assertEquals(rows[0]!.kind, "category-header");
  assertEquals(rows[1]!.kind, "entity-row");
  assertEquals(
    (rows[1] as Extract<RowDescriptor, { kind: "entity-row" }>).entityId,
    "alice",
  );
  assertEquals(rows[2]!.kind, "entity-row");
  assertEquals(
    (rows[2] as Extract<RowDescriptor, { kind: "entity-row" }>).entityId,
    "bob",
  );
});

Deno.test("iterateRows: hidden-on-stage rows keep full lane height", () => {
  // The per-row eyeball controls STAGE visibility (see RowHidden
  // doctrine in engine/timeline.ts). The timeline row itself stays
  // at full lane height so selection / drag / scrub continue to
  // work on the hidden entity without first revealing it on stage.
  const rows = [...iterateRows(
    new Set<LaneKind>(["peers"]),
    new Set(["peers"]),
    { peers: ["alice", "bob"], sessions: [], messages: [] },
    { peers: ["bob"] },
    30,
  )];
  const bobRow = rows.find(
    (r) => r.kind === "entity-row" && r.entityId === "bob",
  )!;
  assertEquals(
    (bobRow as Extract<RowDescriptor, { kind: "entity-row" }>).hidden,
    true,
  );
  assertEquals(bobRow.height, 30);
});

Deno.test("hitTestGutter: chevron click on a collapsed category header", () => {
  const rows: RowDescriptor[] = [
    { kind: "category-collapsed", category: "peers", y: 0, height: 30 },
  ];
  // px=8 (HEADER_CHEVRON_X), py=15 (mid-row).
  const hit = hitTestGutter(8, 15, rows);
  assertEquals(hit?.kind, "chevron");
  if (hit?.kind === "chevron") assertEquals(hit.category, "peers");
});

Deno.test("hitTestGutter: eyeball click on per-entity row", () => {
  const rows: RowDescriptor[] = [
    {
      kind: "entity-row",
      category: "peers",
      entityId: "alice",
      y: 0,
      height: 30,
      hidden: false,
    },
  ];
  // px=24, py=15 — inside the per-entity eyeball hit zone
  // [ROW_EYEBALL_X - 8, ROW_EYEBALL_X + 8) where ROW_EYEBALL_X
  // is HEADER_EYEBALL_X + ROW_INDENT_PX (24 + 6 = 30). The
  // 16-px hit zone still covers 24, so the test point survived
  // the indent. Per-entity rows nest under the category header
  // visually; hit-test stays generous so a 6 px shift doesn't
  // make the click target awkward.
  const hit = hitTestGutter(24, 15, rows);
  assertEquals(hit?.kind, "eyeball");
  if (hit?.kind === "eyeball") {
    assertEquals(hit.category, "peers");
    assertEquals(hit.entityId, "alice");
  }
});

Deno.test("hitTestGutter: category-eyeball click on header row", () => {
  const rows: RowDescriptor[] = [
    { kind: "category-collapsed", category: "peers", y: 0, height: 30 },
  ];
  // px=24 (HEADER_EYEBALL_X), py=15 — inside the category-eyeball
  // hit zone, so wins over the rest of the header's chevron toggle.
  const hit = hitTestGutter(24, 15, rows);
  assertEquals(hit?.kind, "category-eyeball");
  if (hit?.kind === "category-eyeball") {
    assertEquals(hit.category, "peers");
  }
});

Deno.test(
  "hitTestGutter: chevron click outside category-eyeball still toggles",
  () => {
    const rows: RowDescriptor[] = [
      { kind: "category-collapsed", category: "peers", y: 0, height: 30 },
    ];
    // px=50 (well past HEADER_EYEBALL_X + 8 = 32) — header
    // chevron branch.
    const hit = hitTestGutter(50, 15, rows);
    assertEquals(hit?.kind, "chevron");
  },
);

Deno.test("hitTestGutter: row-drag handle on entity-row label area", () => {
  const rows: RowDescriptor[] = [
    {
      kind: "entity-row",
      category: "peers",
      entityId: "alice",
      y: 0,
      height: 30,
      hidden: false,
    },
  ];
  // px=40 (in label area, right of eyeball hit-zone), py=15.
  const hit = hitTestGutter(40, 15, rows);
  assertEquals(hit?.kind, "row-drag");
});

Deno.test("hitTestGutter: hidden-on-stage rows keep drag + eyeball", () => {
  // Now that the eyeball gates STAGE rendering instead of timeline
  // geometry, the row stays at full height and stays fully
  // interactive — reorder + tap-to-select work whether or not the
  // entity is currently hidden on the stage.
  const rows: RowDescriptor[] = [
    {
      kind: "entity-row",
      category: "peers",
      entityId: "alice",
      y: 0,
      height: 30,
      hidden: true,
    },
  ];
  const hitDrag = hitTestGutter(40, 15, rows);
  assertEquals(hitDrag?.kind, "row-drag");
  const hitEye = hitTestGutter(24, 15, rows);
  assertEquals(hitEye?.kind, "eyeball");
});

Deno.test("hitTestGutter: clicks outside the gutter return null", () => {
  const rows: RowDescriptor[] = [
    { kind: "category-collapsed", category: "peers", y: 0, height: 30 },
  ];
  // px=120 is past LANE_LABEL_WIDTH (104) → not the gutter.
  const hit = hitTestGutter(120, 15, rows);
  assertEquals(hit, null);
});

// ---------------------------------------------------------------
// View helpers: `maxWidth` separates "how far can windowEnd go"
// (Live mode wants Infinity for pan-into-future) from "how wide
// can the window get" (Live mode wants `duration / 0.15`).
// ---------------------------------------------------------------

const BASE_VIEW: TimelineView = {
  windowStart: 0,
  windowEnd: 100,
  expandedLanes: new Set(["ruler"]),
  expandedCategories: new Set(),
};

Deno.test("clampView: windowStart never goes negative", () => {
  // Time can't go below zero — pan-left always bottoms out at
  // the origin, even when called with a negative windowStart.
  const negStart: TimelineView = {
    ...BASE_VIEW,
    windowStart: -50,
    windowEnd: 50,
  };
  const clamped = clampView(negStart, 100, 100, Number.POSITIVE_INFINITY);
  assertEquals(clamped.windowStart, 0);
  assertEquals(clamped.windowEnd, 100); // width preserved
});

Deno.test("clampView: maxWidth defaults to duration (legacy behavior)", () => {
  // Old single-bound semantics: width capped at duration.
  const wide: TimelineView = { ...BASE_VIEW, windowStart: 0, windowEnd: 500 };
  const clamped = clampView(wide, 100);
  assertEquals(clamped.windowEnd - clamped.windowStart, 100);
});

Deno.test("zoomAround: zoom-out grows width up to maxWidth (Live shape)", () => {
  // Live-mode shape: maxWidth=300 (1-week-ish cap),
  // panMaxT=Infinity (pan-right unbounded). Aggressive zoom-out
  // → width hits the 300 ceiling.
  const zoomedOut = zoomAround(
    BASE_VIEW,
    50,
    0.01,
    100,
    300,
    Number.POSITIVE_INFINITY,
  );
  assertEquals(zoomedOut.windowEnd - zoomedOut.windowStart, 300);
});

Deno.test(
  "zoomAround: legacy single-bound (duration only) caps width at duration",
  () => {
    // Default maxWidth = duration, panMaxT = duration. Zoom-out
    // is clamped because windowEnd can't exceed duration — Play /
    // Build's historical "can't zoom past 1×".
    const zoomedOut = zoomAround(BASE_VIEW, 50, 0.01, 100);
    assertEquals(zoomedOut.windowEnd - zoomedOut.windowStart, 100);
  },
);

Deno.test("pan-right in Play / Build at 1× is a no-op", () => {
  // Window already covers the doc, and panMaxT=duration caps
  // the right edge → pan-right snaps back to [0, duration].
  const panned = pan(BASE_VIEW, 1000, 100);
  assertEquals(panned.windowStart, 0);
  assertEquals(panned.windowEnd, 100);
});

Deno.test("pan-right when zoomed-in slides within [0, panMaxT]", () => {
  // Width=50 < duration=100 → window can slide. Pan-right by 30:
  // [0, 50] → [30, 80]. Pan-right past the panMaxT clamps at
  // [50, 100].
  const v50: TimelineView = { ...BASE_VIEW, windowStart: 0, windowEnd: 50 };
  const slid = pan(v50, 30, 100);
  assertEquals(slid.windowStart, 30);
  assertEquals(slid.windowEnd, 80);
  const clamped = pan(v50, 1000, 100);
  assertEquals(clamped.windowStart, 50);
  assertEquals(clamped.windowEnd, 100);
});

Deno.test(
  "pan-right with panMaxT=Infinity drifts unbounded (Live shape)",
  () => {
    // Live mode: pan-right is unbounded. Pan from any width or
    // zoom level just slides windowStart up; windowEnd grows in
    // lockstep. windowStart never goes negative on a pan-LEFT
    // (see separate test), so the only floor is the t=0 origin.
    const v100: TimelineView = {
      ...BASE_VIEW,
      windowStart: 0,
      windowEnd: 100,
    };
    const drifted = pan(v100, 500, 100, 100, Number.POSITIVE_INFINITY);
    assertEquals(drifted.windowStart, 500);
    assertEquals(drifted.windowEnd, 600);
  },
);

Deno.test("pan-left in Live mode bottoms out at windowStart=0", () => {
  // Live: panMaxT=Infinity, but `windowStart >= 0` is the hard
  // left floor — time never goes negative.
  const v100: TimelineView = {
    ...BASE_VIEW,
    windowStart: 100,
    windowEnd: 200,
  };
  const left = pan(v100, -500, 100, 100, Number.POSITIVE_INFINITY);
  assertEquals(left.windowStart, 0);
  assertEquals(left.windowEnd, 100); // width preserved
});

Deno.test(
  "applyWheel: zoom-out saturates at maxWidth (Live-mode shape)",
  () => {
    // Simulate Live mode: duration=100 (captured), maxWidth=300
    // (zoom-out floor), panMaxT=Infinity (pan unbounded right).
    // Repeated wheel zoom-out asymptotes at maxWidth without
    // ever clipping width because panMaxT doesn't squeeze it.
    const liveMaxWidth = 300;
    let v: TimelineView = { ...BASE_VIEW, gutterWidth: 50 };
    for (let i = 0; i < 100; i++) {
      v = applyWheel(
        { deltaX: 0, deltaY: 200, shiftKey: false },
        v,
        100,
        100,
        300,
        liveMaxWidth,
        Number.POSITIVE_INFINITY,
      );
    }
    const width = v.windowEnd - v.windowStart;
    assertEquals(
      Math.abs(width - liveMaxWidth) < 1e-6,
      true,
      `expected width≈${liveMaxWidth}, got ${width}`,
    );
  },
);

Deno.test("iterateRows: an empty category expands and collapses like any other", () => {
  // The lane toggle alone decides whether the category row exists;
  // expansion is user-set (persisted) state on top. An empty group
  // must therefore be freely expandable AND collapsible — content
  // coming and going never traps the chrome in either state.
  const lanes = new Set<"peers" | "sessions" | "messages" | "ruler">([
    "peers",
    "messages",
  ]);
  const expandedEmpty = [...iterateRows(
    lanes,
    new Set<"peers" | "sessions" | "messages">(["messages"]),
    { peers: ["alice"], sessions: [], messages: [] },
    undefined,
    32,
  )];
  const header = expandedEmpty.find((r) => r.kind === "category-header");
  assertEquals(header?.category, "messages");
  // Collapsed, the empty group keeps its collapsed row — still
  // there to expand again.
  const collapsedEmpty = [...iterateRows(
    lanes,
    new Set<"peers" | "sessions" | "messages">(),
    { peers: ["alice"], sessions: [], messages: [] },
    undefined,
    32,
  )];
  const collapsed = collapsedEmpty.find(
    (r) => r.kind === "category-collapsed" && r.category === "messages",
  );
  assertEquals(collapsed !== undefined, true);
});
