/**
 * Moving a moment along its own track: a drop on a neighbour is
 * refused, a drop on another property's time is not, and the
 * observation keeps its name.
 */

import { assert, assertEquals } from "@std/assert";
import { Engine } from "../../engine.ts";
import { sessionTrajectoryRows } from "../../trajectory.ts";
import { buildDoc, engineTest, sessionOf } from "./harness.ts";

// ── moving a moment along its own track ───────────────────────────

/** The two moments of `s1`'s state track, by the observation each is. */
function stateMoments(e: Engine) {
  return sessionTrajectoryRows(e.doc, "s1").filter((m) => m.property === "state");
}

engineTest("a moment dropped on its own neighbour is refused", () => {
  const e = new Engine(buildDoc());
  e.dispatch({
    kind: "set-session-keyframe",
    sessionId: "s1",
    property: "state",
    t: 1000,
    value: "open",
  });
  e.dispatch({
    kind: "set-session-keyframe",
    sessionId: "s1",
    property: "state",
    t: 2000,
    value: "draining",
  });
  const before = stateMoments(e);
  assertEquals(before.length, 2);
  const later = before[1]!;

  // The row's scrub clamps to its predecessor's time, and the floor is
  // reachable. Landing there once meant remove-then-set, and the set
  // REPLACES at its t — so the predecessor was overwritten and the
  // track came back one entry short.
  const errors: string[] = [];
  const off = e.onError((err) => errors.push(err.detail));
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: later.eventId, newT: 1000 },
  });
  off();

  const after = stateMoments(e);
  assertEquals(after.length, 2, "the track lost a moment to the drag");
  assertEquals(after.map((m) => m.t), [1000, 2000]);
  assertEquals(after.map((m) => m.value), ["open", "draining"]);
  assert(errors.length > 0, "the refusal was silent");
});

engineTest("a moment may land where ANOTHER property states one", () => {
  const e = new Engine(buildDoc());
  e.dispatch({
    kind: "set-session-keyframe",
    sessionId: "s1",
    property: "state",
    t: 1000,
    value: "open",
  });
  e.dispatch({
    kind: "set-session-keyframe",
    sessionId: "s1",
    property: "b",
    t: 3000,
    value: "b",
  });
  // The two tracks are read separately and neither shadows the other,
  // so an end's moment is no constraint on the state's.
  const endMoment = sessionTrajectoryRows(e.doc, "s1").find((m) => m.property === "b")!;
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: endMoment.eventId, newT: 1000 },
  });
  const rows = sessionTrajectoryRows(e.doc, "s1");
  assertEquals(rows.length, 2);
  assertEquals(rows.map((m) => m.t), [1000, 1000]);
});

engineTest("a moment moved along its own track keeps its name", () => {
  const e = new Engine(buildDoc());
  e.dispatch({
    kind: "set-session-keyframe",
    sessionId: "s1",
    property: "state",
    t: 1000,
    value: "open",
  });
  const before = stateMoments(e)[0]!;
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: before.eventId, newT: 4000 },
  });
  const after = stateMoments(e)[0]!;
  assertEquals(after.eventId, before.eventId);
  assertEquals(after.t, 4000);
  // The definition's track went with it — the Inspector reads the
  // moments and the stage reads the track, and they must agree.
  assertEquals(sessionOf(e).keyframes?.state, [{ t: 4000, value: "open" }]);
});
