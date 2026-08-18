/**
 * The session's state property: stating a value from a moment, taking
 * that moment back, and the genesis state that is not a moment.
 */

import { assert, assertEquals } from "@std/assert";
import { Engine } from "../../engine.ts";
import { buildDoc, engineTest, sessionOf } from "./harness.ts";

// ── the state property ────────────────────────────────────────────

engineTest("setSessionKeyframe inserts a state keyframe at t", () => {
  const e = new Engine(buildDoc());
  e.setSessionKeyframe("s1", "state", 1000, "open");
  assertEquals(sessionOf(e).keyframes?.state, [{ t: 1000, value: "open" }]);
});

engineTest("setSessionKeyframe replaces the value at the same t", () => {
  const e = new Engine(buildDoc());
  e.setSessionKeyframe("s1", "state", 1000, "open");
  e.setSessionKeyframe("s1", "state", 1000, "draining");
  assertEquals(sessionOf(e).keyframes?.state, [{ t: 1000, value: "draining" }]);
});

engineTest("setSessionKeyframe keeps the track sorted", () => {
  const e = new Engine(buildDoc());
  e.setSessionKeyframe("s1", "state", 3000, "draining");
  e.setSessionKeyframe("s1", "state", 1000, "open");
  e.setSessionKeyframe("s1", "state", 2000, "open");
  assertEquals(
    sessionOf(e).keyframes?.state?.map((kf) => kf.t),
    [1000, 2000, 3000],
  );
});

engineTest("setSessionKeyframe rejects t before the effective start", () => {
  const e = new Engine(buildDoc());
  e.setSessionStart("s1", 500);
  e.setSessionKeyframe("s1", "state", 100, "open");
  const track = sessionOf(e).keyframes?.state;
  assert(!track || track.length === 0, "out-of-window keyframe was stored");
});

engineTest("removeSessionKeyframe removes the state keyframe at t", () => {
  const e = new Engine(buildDoc());
  e.setSessionKeyframe("s1", "state", 1000, "open");
  e.setSessionKeyframe("s1", "state", 2000, "draining");
  e.removeSessionKeyframe("s1", "state", 1000);
  assertEquals(sessionOf(e).keyframes?.state, [{ t: 2000, value: "draining" }]);
});

engineTest("removeSessionKeyframe is a no-op when no t matches", () => {
  const e = new Engine(buildDoc());
  e.setSessionKeyframe("s1", "state", 1000, "open");
  e.removeSessionKeyframe("s1", "state", 1234);
  assertEquals(sessionOf(e).keyframes?.state, [{ t: 1000, value: "open" }]);
});

engineTest("setSessionInitialState edits row 0 (entity.initialState)", () => {
  const e = new Engine(buildDoc());
  e.setSessionInitialState("s1", "open");
  assertEquals(sessionOf(e).initialState, "open");
});

engineTest(
  "dispatch routes set-session-keyframe through the intent path",
  () => {
    const e = new Engine(buildDoc());
    e.dispatch({
      kind: "set-session-keyframe",
      sessionId: "s1",
      property: "state",
      t: 1500,
      value: "open",
    });
    assertEquals(sessionOf(e).keyframes?.state, [{ t: 1500, value: "open" }]);
  },
);

engineTest(
  "dispatch no-op guard skips set-session-keyframe when unchanged",
  () => {
    const e = new Engine(buildDoc());
    e.setSessionKeyframe("s1", "state", 1000, "open");
    const v0 = e.version;
    e.dispatch({
      kind: "set-session-keyframe",
      sessionId: "s1",
      property: "state",
      t: 1000,
      value: "open",
    });
    // No-op guard short-circuits dispatch → no version bump.
    assertEquals(e.version, v0);
  },
);
