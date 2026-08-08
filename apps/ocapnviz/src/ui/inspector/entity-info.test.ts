/**
 * The Inspector's off-stage resolvers.
 *
 * When the playhead sits outside an entity's window there is no ECS
 * entity to read, so these fall back to the document. The fallback
 * has to answer the same question the stage would: what is this
 * entity's value AT the playhead — not the value it was created
 * with. Reading the genesis value instead is the same defect the
 * stage had for peer names, one layer over.
 */

import { assertEquals } from "@std/assert";
import { Engine } from "../../engine/engine.ts";
import { TimelineDocument } from "../../engine/timeline.ts";
import { peerInfo, sessionInfo, sessionsTouchingPeer } from "./entity-info.ts";

/** Engine construction runs d3-force, whose timer Deno's sanitizer
 *  flags; same workaround as the other engine-constructing tests. */
function engineTest(name: string, fn: () => void): void {
  Deno.test({ name, sanitizeOps: false, sanitizeResources: false, fn });
}

/** Alice and Bob hold one session from t=100 to t=400. Bob is
 *  renamed at t=200; the session opens negotiating and reaches open
 *  at t=250. Everything is over by t=400, so a playhead past it
 *  reads through the document rather than the world. */
function doc(): TimelineDocument {
  return TimelineDocument.parse({
    id: "entity-info-test",
    duration: 1000,
    events: [
      {
        id: "e1",
        t: 100,
        kind: "peer-joined",
        peerId: "alice",
        profile: "pancake",
      },
      {
        id: "e2",
        t: 100,
        kind: "peer-joined",
        peerId: "bob",
        profile: "pancake",
        label: "127.0.0.1:0",
      },
      {
        id: "e3",
        t: 100,
        kind: "session-opened",
        sessionId: "s1",
        a: { peer: "alice" },
        b: { peer: "bob" },
        codec: "syrup",
        captpVersion: "v1_0",
        initialState: "negotiating",
      },
      { id: "e4", t: 200, kind: "peer-updated", peerId: "bob", label: "carol" },
      {
        id: "e5",
        t: 250,
        kind: "session-state-changed",
        sessionId: "s1",
        state: "open",
      },
      { id: "e6", t: 400, kind: "session-closed", sessionId: "s1" },
      { id: "e7", t: 400, kind: "peer-left", peerId: "bob" },
    ],
  });
}

engineTest("an off-stage peer reports the name it had at the playhead", () => {
  const engine = new Engine(doc());
  engine.seekTo(900);
  assertEquals(peerInfo(engine, "bob")?.label, "carol");
  assertEquals(peerInfo(engine, "bob")?.lifecycle, "after");
});

engineTest(
  "an off-stage session reports the state it was in, not its first",
  () => {
    const engine = new Engine(doc());
    engine.seekTo(900);
    assertEquals(sessionInfo(engine, "s1")?.state, "open");
  },
);

engineTest("scrubbing back reports what each entity was then", () => {
  const engine = new Engine(doc());
  // t=150: bob still under its locator, session still negotiating.
  engine.seekTo(150);
  assertEquals(peerInfo(engine, "bob")?.label, "127.0.0.1:0");
  assertEquals(sessionInfo(engine, "s1")?.state, "negotiating");
});

engineTest("a peer's sessions are the ones it is an end of", () => {
  const engine = new Engine(doc());
  assertEquals(sessionsTouchingPeer(engine, "alice"), ["s1"]);
  assertEquals(sessionsTouchingPeer(engine, "bob"), ["s1"]);
});

/** A session opened with one loose end, which a later observation attributes
 *  to `dana`. The list has to name that session for dana too: the end was
 *  hers throughout, and only the viewer's name for it arrived late. */
engineTest("a peer that took an end later is still on that session", () => {
  const engine = new Engine(TimelineDocument.parse({
    id: "entity-info-late-end",
    duration: 1000,
    events: [
      {
        id: "e1",
        t: 0,
        kind: "peer-joined",
        peerId: "host",
        profile: "pancake",
      },
      {
        id: "e2",
        t: 0,
        kind: "peer-joined",
        peerId: "dana",
        profile: "goblins",
      },
      {
        id: "e3",
        t: 100,
        kind: "session-opened",
        sessionId: "s9",
        a: {
          peer: "host",
          designator: "tcp://host",
          attributedBy: "self-reported",
        },
        b: { designator: "tcp://who" },
        codec: "syrup",
        captpVersion: "v1_0",
      },
      {
        id: "e4",
        t: 200,
        kind: "session-endpoint-attributed",
        sessionId: "s9",
        side: "b",
        peerId: "dana",
      },
    ],
  }));
  // Before the attribution as much as after it: the row is about the
  // document, and its lifecycle chip is what speaks about the playhead.
  engine.seekTo(150);
  assertEquals(sessionsTouchingPeer(engine, "dana"), ["s9"]);
  engine.seekTo(300);
  assertEquals(sessionsTouchingPeer(engine, "dana"), ["s9"]);
  // And a peer on neither end is on no session.
  assertEquals(sessionsTouchingPeer(engine, "tcp://who"), []);
});
