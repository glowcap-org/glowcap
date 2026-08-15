/**
 * One end of a session, resolved at a moment.
 *
 * An end attaches to a peer BECAUSE something backed it, so who is there and
 * what put them there are one fact arriving at one instant. These hold that
 * the reader gives both from the same moment: the bug they were written
 * against read the peer at the playhead and the attribution off the endpoint
 * the session was born with, so a session whose end a signed handoff attached
 * at t=3500 reported "attached to Bob" beside "nothing proved this".
 *
 * They run the whole path a live capture takes — observations in,
 * `projectFromObservations`, then the resolver — because that is where the
 * pair has to survive: the endpoint tracks are re-derived from the stream on
 * every projection run, so a value that drops half of itself in the index
 * drops it for good.
 *
 * Validated by breaking the code they cover, one defect at a time, and
 * confirming each was caught: the attribution read off the genesis endpoint
 * while the peer is read at the playhead (the original bug), the projection
 * dropping `attributedBy` as it builds the keyframe, the resolver dropping the
 * genesis claim from the resolved end, and the projection inventing a backing
 * where the observation stated none.
 *
 * One defect ESCAPED, and it is worth knowing: fabricating a backing inside
 * `SESSION_TRAJECTORY[side].read` changed nothing here, because the projection
 * builds each keyframe from the observation directly and `read` is not on this
 * path at all — it serves the trajectory ROW, which shows the peer alone. A
 * green run here says nothing about what a row displays.
 */

import { assert, assertEquals } from "@std/assert";
import { attachedEndpoint, sessionEndpoint } from "../../schema/topology.ts";
import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import { projectFromObservations } from "./project-from-observations.ts";
import { messageEffective, sessionEffective, sessionEndpointAt, sessionEndpointPlaceAt } from "./doc-resolver.ts";

/** A one-session capture: the session opens with `b` loose and carrying a
 *  claim, and whatever moments the case adds land after it. */
function captureWith(...moments: TimelineEvent[]): TimelineDocument {
  const doc = {
    id: "cap",
    duration: 10_000,
    recording: {
      sources: [{
        id: "live",
        meta: { kind: "pancake-host" as const },
        observations: [
          {
            id: "e1",
            t: 0,
            kind: "peer-joined" as const,
            peerId: "rooms",
            profile: "pancake",
          },
          {
            id: "e2",
            t: 0,
            kind: "peer-joined" as const,
            peerId: "bob",
            profile: "pancake",
          },
          {
            id: "e3",
            t: 1000,
            kind: "session-opened" as const,
            sessionId: "w1",
            a: attachedEndpoint("rooms"),
            b: sessionEndpoint({ designator: "127.0.0.1:0" }),
            codec: "syrup" as const,
            captpVersion: "v1_0" as const,
            initialState: "open" as const,
          },
          ...moments,
        ],
      }],
    },
  } as unknown as TimelineDocument;
  return projectFromObservations(doc);
}

const attributed = (
  t: number,
  attributedBy?: "verified-handoff" | "viewer-correlated",
): TimelineEvent =>
  ({
    id: `att-${t}`,
    t,
    kind: "session-endpoint-attributed",
    sessionId: "w1",
    side: "b",
    peerId: "bob",
    ...(attributedBy !== undefined && { attributedBy }),
  }) as TimelineEvent;

Deno.test("a mid-session attachment says what backed it", () => {
  const doc = captureWith(attributed(3500, "verified-handoff"));
  const at = sessionEndpointPlaceAt(doc, "w1", "b", 4000);
  assertEquals(at.peer, "bob");
  assertEquals(
    at.attributedBy,
    "verified-handoff",
    "the end attached and the reader could not say what put it there",
  );
});

Deno.test("before the moment the end is loose, and says nothing backed it", () => {
  const doc = captureWith(attributed(3500, "verified-handoff"));
  const before = sessionEndpointPlaceAt(doc, "w1", "b", 3499);
  assertEquals(before.peer, undefined);
  assertEquals(before.attributedBy, undefined);
  // Loose ends draw at a node of their own, which is what the stage reaches.
  assertEquals(before.node, "w1::b");
  // And the attachment takes effect AT its own t, not the instant after.
  assertEquals(sessionEndpointPlaceAt(doc, "w1", "b", 3500).peer, "bob");
});

Deno.test("the end keeps its claim across the attachment", () => {
  // The claim is stated once, when the session opens, and attaching does not
  // restate it — so it comes off the genesis end at every moment. An end that
  // lost its claim the instant it attached would erase what the far side had
  // said of itself.
  const doc = captureWith(attributed(3500, "verified-handoff"));
  for (const t of [1000, 3499, 3500, 9000]) {
    assertEquals(
      sessionEndpointAt(doc, "w1", "b", t).designator,
      "127.0.0.1:0",
      `the claim was gone at t=${t}`,
    );
  }
});

Deno.test("an attachment nothing backed attaches without inventing a word", () => {
  // The invariant runs one way: something that attributed an end names the
  // peer, and an end may be attached with nothing recorded about what put it
  // there. Requiring a word here would make an author's write invent one.
  const doc = captureWith(attributed(3500));
  const at = sessionEndpointPlaceAt(doc, "w1", "b", 4000);
  assertEquals(at.peer, "bob");
  assertEquals(at.attributedBy, undefined);
});

Deno.test("the pair survives the projection that re-derives the track", () => {
  // The endpoint tracks are the projection's product of the observations and
  // are rebuilt on every run, so this is where half a pair goes missing.
  const doc = captureWith(attributed(3500, "verified-handoff"));
  const track = doc.entities?.sessions?.["w1"]?.keyframes?.b;
  assertEquals(track, [{
    t: 3500,
    value: { peer: "bob", attributedBy: "verified-handoff" },
  }]);
  // Re-running is idempotent, so a second pass neither drops the backing nor
  // reports a change.
  const again = projectFromObservations(doc);
  assert(again === doc, "a quiet re-projection rebuilt the document");
});

Deno.test("a later attribution supersedes an earlier one, backing and all", () => {
  const doc = captureWith(
    attributed(2000, "viewer-correlated"),
    attributed(3500, "verified-handoff"),
  );
  assertEquals(
    sessionEndpointPlaceAt(doc, "w1", "b", 2500).attributedBy,
    "viewer-correlated",
  );
  assertEquals(
    sessionEndpointPlaceAt(doc, "w1", "b", 3500).attributedBy,
    "verified-handoff",
  );
});

/** A peer that arrives partway through, and the moment the loose end attaches
 *  to it. The pair is the live feed's ordinary shape: a host accepts a dialer
 *  it cannot name, and a second producer speaks for that end later. */
const latecomer = (t: number): TimelineEvent[] => [
  {
    id: `join-${t}`,
    t,
    kind: "peer-joined",
    peerId: "carol",
    profile: "pancake",
  } as TimelineEvent,
  {
    id: `att-carol-${t}`,
    t,
    kind: "session-endpoint-attributed",
    sessionId: "w1",
    side: "b",
    peerId: "carol",
    attributedBy: "viewer-correlated",
  } as TimelineEvent,
];

Deno.test("a session born with a loose end runs from its own open", () => {
  // The end was there and unoccupied from t=1000, and somebody arrived at it
  // at t=3500. Dating the end from that arrival dates the SESSION from it, so
  // the 2500ms everyone observed would vanish — and it would vanish only once
  // the attribution had arrived, which is why a recording and the live feed
  // that produced it disagreed about the same moment.
  const doc = captureWith(...latecomer(3500));
  assertEquals(sessionEffective(doc, "w1").start, 1000);
});

Deno.test("a message carried before the far end was named stays in the picture", () => {
  // A message's context is its session, so a session that lost its opening
  // takes every message it carried there with it.
  const doc = captureWith(
    {
      id: "m1",
      t: 1500,
      kind: "message-sent",
      messageId: "msg-1",
      sessionId: "w1",
      from: "rooms",
      to: "w1::b",
      arrivalT: 1600,
    } as TimelineEvent,
    ...latecomer(3500),
  );
  assertEquals(messageEffective(doc, "msg-1"), { start: 1500, end: 1600 });
});

Deno.test("a genesis attachment reads at every moment of the session", () => {
  // The genesis end is not a special case: it is the pair stated at the
  // session's own start rather than the only place it can be stated.
  const doc = captureWith();
  const born = sessionEndpointPlaceAt(doc, "w1", "a", 5000);
  assertEquals(born.peer, "rooms");
  assertEquals(born.attributedBy, undefined);
  assertEquals(born.node, "rooms");
});
