/**
 * What the group-selection panel claims about a selection.
 *
 * Every assertion here is a string or a number the reader sees, so
 * the test reads them the way the panel does: a count is checked
 * against the set it names, and a plural is checked at one as well as
 * at several. A summary that is subtly wrong is worse than a sparse
 * one, and nothing else in the app would notice it drifting.
 */

import { assertEquals } from "@std/assert";
import { Engine } from "../../engine/engine.ts";
import { TimelineDocument } from "../../engine/timeline.ts";
import type { EntityRefKey } from "../../interactions/types.ts";
import {
  bulkShiftPlan,
  countPhrase,
  deletionPhrase,
  kindNoun,
  selectionFacts,
  selectionPhrase,
  shiftCaveats,
  tallyByKind,
} from "./selection-summary.ts";

function keys(...k: string[]): ReadonlySet<EntityRefKey> {
  return new Set(k as EntityRefKey[]);
}

/** Three peers, three sessions and a message. `alice` and `bob` hold
 *  both ends of `alice-bob`; `carol-loose` has one end nobody has
 *  attributed. `ghost` is a peer with no `peer-joined` event, so
 *  nothing in the recording says when it begins. */
function doc(): TimelineDocument {
  return TimelineDocument.parse({
    id: "selection-summary",
    duration: 10000,
    events: [
      {
        id: "e-alice",
        t: 0,
        kind: "peer-joined",
        peerId: "alice",
        profile: "pancake",
      },
      {
        id: "e-bob",
        t: 1000,
        kind: "peer-joined",
        peerId: "bob",
        profile: "goblins",
      },
      {
        id: "e-carol",
        t: 1000,
        kind: "peer-joined",
        peerId: "carol",
        profile: "pancake",
      },
      {
        id: "e-alice-bob",
        t: 2000,
        kind: "session-opened",
        sessionId: "alice-bob",
        a: { peer: "alice", attributedBy: "self-reported" },
        b: { peer: "bob", attributedBy: "self-reported" },
        codec: "capnp",
        captpVersion: "next",
        initialState: "open",
      },
      {
        id: "e-alice-carol",
        t: 2500,
        kind: "session-opened",
        sessionId: "alice-carol",
        a: { peer: "alice", attributedBy: "self-reported" },
        b: { peer: "carol", attributedBy: "self-reported" },
        codec: "syrup",
        captpVersion: "v1_0",
        initialState: "open",
      },
      {
        id: "e-carol-loose",
        t: 3000,
        kind: "session-opened",
        sessionId: "carol-loose",
        a: { peer: "carol", attributedBy: "self-reported" },
        b: { designator: "127.0.0.1:9000" },
        codec: "syrup",
        captpVersion: "v1_0",
        initialState: "open",
      },
      {
        id: "e-msg",
        t: 4000,
        kind: "message-sent",
        messageId: "m1",
        sessionId: "alice-bob",
        from: "alice",
        to: "bob",
        arrivalT: 4500,
      },
      {
        id: "e-msg-in",
        t: 4500,
        kind: "message-delivered",
        messageId: "m1",
      },
    ],
    entities: {
      peers: {
        // A peer the document holds but no observation opens: its
        // start is implicit, so a shift has no event to move.
        ghost: { id: "ghost", label: "Ghost", profile: "other" },
      },
    },
  });
}

function engineAt(t: number): Engine {
  const engine = new Engine(doc());
  engine.enqueue({ kind: "seekTo", t });
  engine.tick(0);
  return engine;
}

// ── the words ──────────────────────────────────────────────────────

Deno.test("a count carries the noun that count takes", () => {
  assertEquals(countPhrase("peer", 1), "1 peer");
  assertEquals(countPhrase("peer", 3), "3 peers");
  assertEquals(countPhrase("session", 1), "1 session");
  assertEquals(countPhrase("endpoint", 1), "1 session end");
  assertEquals(countPhrase("endpoint", 2), "2 session ends");
  assertEquals(countPhrase("message", 0), "0 messages");
  assertEquals(kindNoun("message", 1), "message");
});

Deno.test("the phrase names every kind the selection holds", () => {
  const one = tallyByKind(keys("peer:alice", "peer:bob"));
  assertEquals(selectionPhrase(one), "2 peers");

  const two = tallyByKind(keys("peer:alice", "session:alice-bob"));
  assertEquals(selectionPhrase(two), "1 peer and 1 session");

  const three = tallyByKind(
    keys("peer:alice", "session:alice-bob", "message:m1", "message:m2"),
  );
  assertEquals(selectionPhrase(three), "1 peer, 1 session and 2 messages");
});

Deno.test("the phrase orders kinds the same way whatever order they arrived in", () => {
  const forward = tallyByKind(keys("peer:alice", "message:m1"));
  const backward = tallyByKind(keys("message:m1", "peer:alice"));
  assertEquals(selectionPhrase(forward), selectionPhrase(backward));
  assertEquals(selectionPhrase(forward), "1 peer and 1 message");
});

Deno.test("a delete phrase counts only what a delete takes", () => {
  // A session end cannot be deleted on its own, so the phrase leaves
  // it out rather than promising to take it.
  assertEquals(
    deletionPhrase(keys("peer:alice", "endpoint:carol-loose::b")),
    "1 peer",
  );
  assertEquals(deletionPhrase(keys("endpoint:carol-loose::b")), null);
  assertEquals(
    deletionPhrase(keys("peer:alice", "peer:bob", "session:alice-bob")),
    "2 peers and 1 session",
  );
});

// ── the facts ──────────────────────────────────────────────────────

Deno.test("the span reaches from the earliest start to the latest end", () => {
  const engine = engineAt(3000);
  const facts = selectionFacts(engine, keys("message:m1", "session:alice-bob"));
  // The session opens before the message is sent; the message lands
  // after — and the session, which nothing closes, runs to the end of
  // the document, which is where the timeline draws it too.
  assertEquals(facts.span, { start: 2000, end: 10000 });

  const bounded = selectionFacts(engine, keys("message:m1"));
  assertEquals(bounded.span, { start: 4000, end: 4500 });
});

Deno.test("a session end takes the span of the session it is an end of", () => {
  const engine = engineAt(3000);
  const end = selectionFacts(
    engine,
    keys("endpoint:carol-loose::b", "peer:alice"),
  );
  const session = selectionFacts(
    engine,
    keys("session:carol-loose", "peer:alice"),
  );
  assertEquals(end.span, session.span);
});

Deno.test("a selected id the document does not hold stays out of the span", () => {
  const engine = engineAt(3000);
  const real = selectionFacts(engine, keys("peer:alice", "peer:bob"));
  const withGhostId = selectionFacts(
    engine,
    keys("peer:alice", "peer:bob", "peer:not-a-peer"),
  );
  assertEquals(withGhostId.span, real.span);
  // It is still one of the things the reader selected, so the total
  // counts it.
  assertEquals(withGhostId.total, 3);
});

Deno.test("on-stage counts the selection at the playhead, not the document", () => {
  // At t=1500 alice and bob have joined, carol has joined, and no
  // session has opened yet.
  const early = selectionFacts(
    engineAt(1500),
    keys("peer:alice", "session:alice-bob"),
  );
  assertEquals(early.total, 2);
  assertEquals(early.onStage, 1);

  // At t=2600 both sessions are open, so all three are on stage.
  const later = selectionFacts(
    engineAt(2600),
    keys("peer:alice", "session:alice-bob", "session:alice-carol"),
  );
  assertEquals(later.onStage, 3);
});

Deno.test("a message counts as on stage only while it is in flight", () => {
  assertEquals(selectionFacts(engineAt(4200), keys("message:m1")).onStage, 1);
  assertEquals(selectionFacts(engineAt(4800), keys("message:m1")).onStage, 0);
});

Deno.test("between counts the sessions whose two ends are both selected", () => {
  const engine = engineAt(3500);
  // alice-bob has both its peers selected; alice-carol has one.
  const facts = selectionFacts(
    engine,
    keys("peer:alice", "peer:bob", "session:alice-bob", "session:alice-carol"),
  );
  assertEquals(facts.between, { closed: 1, sessions: 2 });
});

Deno.test("a session with an end nobody attributed is not between two peers", () => {
  const engine = engineAt(3500);
  const facts = selectionFacts(
    engine,
    keys("peer:carol", "session:carol-loose"),
  );
  assertEquals(facts.between, { closed: 0, sessions: 1 });
});

Deno.test("between is not asked when the selection has no peer or no session", () => {
  const engine = engineAt(3500);
  assertEquals(
    selectionFacts(engine, keys("peer:alice", "peer:bob")).between,
    null,
  );
  assertEquals(
    selectionFacts(engine, keys("session:alice-bob", "message:m1")).between,
    null,
  );
});

// ── the shift ──────────────────────────────────────────────────────

Deno.test("the shift plans one event per selected entity: its genesis", () => {
  const engine = engineAt(0);
  const plan = bulkShiftPlan(
    engine,
    keys("peer:alice", "session:alice-bob", "message:m1"),
  );
  assertEquals(
    plan.events.map((e) => e.id).sort(),
    ["e-alice", "e-alice-bob", "e-msg"],
  );
  // The ending of each rides its genesis inside the engine's own
  // translate, so naming it here would move it twice.
  assertEquals(plan.events.some((e) => e.id === "e-msg-in"), false);
  assertEquals(plan.eternal, 0);
  assertEquals(plan.ends, 0);
});

Deno.test("the plan captures the time each event held, so a shift is relative", () => {
  const plan = bulkShiftPlan(engineAt(0), keys("session:alice-bob"));
  assertEquals(plan.events, [{ id: "e-alice-bob", t: 2000 }]);
});

Deno.test("an entity no observation begins is counted, not silently skipped", () => {
  const plan = bulkShiftPlan(engineAt(0), keys("peer:alice", "peer:ghost"));
  assertEquals(plan.events.map((e) => e.id), ["e-alice"]);
  assertEquals(plan.eternal, 1);
  assertEquals(plan.ends, 0);
});

Deno.test("a session end is counted as an end, never as a missing start", () => {
  const plan = bulkShiftPlan(
    engineAt(0),
    keys("peer:alice", "endpoint:carol-loose::b"),
  );
  assertEquals(plan.eternal, 0);
  assertEquals(plan.ends, 1);
});

Deno.test("the caveats say which set they counted, in the plural it takes", () => {
  assertEquals(shiftCaveats({ events: [], eternal: 0, ends: 0 }, 4), []);
  assertEquals(
    shiftCaveats({ events: [], eternal: 1, ends: 0 }, 4),
    [
      "One of the 4 selected has no start event, so the shift leaves it " +
      "where it is.",
    ],
  );
  assertEquals(
    shiftCaveats({ events: [], eternal: 2, ends: 0 }, 4),
    [
      "2 of the 4 selected have no start event, so the shift leaves them " +
      "where they are.",
    ],
  );
  const both = shiftCaveats({ events: [], eternal: 1, ends: 2 }, 5);
  assertEquals(both.length, 2);
  assertEquals(
    both[1],
    "The 2 selected session ends have no time of their own; they move " +
      "when their sessions do.",
  );
});

Deno.test("every selected entity is accounted for exactly once", () => {
  // The two caveat counts plus the planned events must cover the
  // whole selection — a member that is neither moved nor mentioned is
  // the silent skip this panel exists to stop.
  const selection = keys(
    "peer:alice",
    "peer:ghost",
    "session:alice-bob",
    "endpoint:carol-loose::b",
    "message:m1",
  );
  const plan = bulkShiftPlan(engineAt(0), selection);
  assertEquals(
    plan.events.length + plan.eternal + plan.ends,
    selection.size,
  );
});
