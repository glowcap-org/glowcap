/**
 * Shared geometry and document fixtures for hit-test events.
 *
 * Geometry the tests assume:
 *   width            = 224
 *   LANE_LABEL_WIDTH = 104 (constant in state.ts; bumped from 80
 *                           to fit chevron + category-eyeball +
 *                           category label)
 *   plotWidth        = 120
 *   windowStart..End = 0..1000
 *   → t→px:  px(t) = 104 + (t / 1000) * 120
 *   → t=500 → px=164;  t=1000 → px=224;  t=800 → px=200
 *
 *   RULER_HEIGHT = 22; LANE_GAP = 2; laneHeight = 30
 *   expanded = {peers, sessions, messages}
 *   → height = RULER + 3*(LH+GAP) = 22 + 96 = 118
 *   → peer lane y ∈ [0, 32), session ∈ [32, 64), messages ∈ [64, 96)
 *     ruler ∈ [96, 118)
 */

import { iterateRows, type RowDescriptor } from "../row-layout.ts";
import type { TimelineDocument, TimelineEvent } from "../../../engine/timeline.ts";
import { projectFromObservations } from "../../../engine/temporal/project-from-observations.ts";
import { type LaneKind, type TimelineView } from "../state.ts";
import type { DragPlan } from "../hit-test.ts";

/** Assert the plan is event-addressed and return its eventId — the
 * loaded-fixture cases below all expect the event-addressed variants;
 * entity-addressed plans (freshly authored spans) have their own cases. */
export function eventIdOf(plan: DragPlan | null): string {
  if (plan === null || !("eventId" in plan)) {
    throw new Error("expected an event-addressed drag plan");
  }
  return plan.eventId;
}

export const VIEW: TimelineView = {
  windowStart: 0,
  windowEnd: 1000,
  expandedLanes: new Set<LaneKind>(["peers", "sessions", "messages"]),
  // Categories collapsed (today's default look). Expanded
  // per-entity rows are covered in `events.test.ts`.
  expandedCategories: new Set(),
};
// Width chosen so the plot is exactly 120 px after subtracting the
// 104 px gutter AND the 4 px left + 4 px right pad — keeps the pixel
// arithmetic in the docstring above tractable and isolates these
// tests from gutter-default / pad changes.
export const WIDTH = 232;
export const HEIGHT = 118;
export const LANE_HEIGHT = 30;

export function makePeer(id: string, joinT: number, leftT?: number): TimelineEvent[] {
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

/** Build a minimal TimelineDocument from `events` so hitTestEvents
 *  can resolve span shapes through the same `*Effective` helpers the
 *  renderer uses. Mirrors how production builds the doc: store
 *  observations on a fixture recording source and run
 *  `projectFromObservations` to seed `entities.*.timing`. */
export function docFor(events: readonly TimelineEvent[]): TimelineDocument {
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

/** Build the row layout the renderer would paint for `events`,
 *  using the test fixture's collapsed-categories VIEW. Always
 *  injects a placeholder per category so the test's py-values
 *  (HEIGHT = 22 + 3·32 layout) hit the expected lanes regardless
 *  of what events the specific test supplies. Empty categories still
 *  get a row — `row-layout.test.ts` pins that walk. */
export function rowsFor(events: readonly TimelineEvent[]): RowDescriptor[] {
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
