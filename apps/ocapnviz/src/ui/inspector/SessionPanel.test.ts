/**
 * What the session inspector's trajectory offers to insert.
 *
 * The rows themselves come from `engine/trajectory.ts` and are tested
 * there; this is the one piece of policy the panel owns. A new moment
 * has to arrive saying something true, and for a session's ends
 * "true" can be "nothing" — so the offer either carries a real peer
 * or is not made at all.
 */

import { assert, assertEquals } from "@std/assert";
import { Engine } from "../../engine/engine.ts";
import { TimelineDocument } from "../../engine/timeline.ts";
import { trajectoryInsertOffers } from "./SessionTrajectory.tsx";
import {
  SESSION_PROPERTIES,
  SESSION_TRAJECTORY,
  type SessionProperty,
  type SessionValue,
} from "../../engine/trajectory.ts";

function engineFor(doc: TimelineDocument): Engine {
  return new Engine(doc);
}

/** One session, one end attached and one loose, plus a second peer
 *  nobody has attached yet. */
function looseDoc(): TimelineDocument {
  return TimelineDocument.parse({
    id: "offers",
    duration: 10000,
    events: [
      {
        id: "p1",
        t: 0,
        kind: "peer-joined",
        peerId: "alice",
        profile: "pancake",
      },
      {
        id: "p2",
        t: 0,
        kind: "peer-joined",
        peerId: "bob",
        profile: "goblins",
      },
      {
        id: "so",
        t: 0,
        kind: "session-opened",
        sessionId: "s1",
        a: { peer: "alice", attributedBy: "self-reported" },
        b: { designator: "127.0.0.1:9000" },
        codec: "syrup",
        captpVersion: "v1_0",
        initialState: "open",
      },
    ],
  });
}

/** A session drawn with no peers at all — both ends loose. The
 *  document admits it, so Build mode can make it. */
function peerlessDoc(): TimelineDocument {
  return TimelineDocument.parse({
    id: "peerless",
    duration: 10000,
    entities: {
      sessions: {
        s1: {
          a: { designator: "one" },
          b: { designator: "two" },
          codec: "syrup",
          captpVersion: "v1_0",
        },
      },
    },
  });
}

/** The word an offer proposes, read through the property's own `stated`
 *  channel: an offer carries the property's whole value, and for an end
 *  that is the pair (the peer, and what backed it). */
function valueOf(
  offers: { property: SessionProperty; value: SessionValue }[],
  property: SessionProperty,
): string | undefined {
  const offer = offers.find((o) => o.property === property);
  return offer === undefined
    ? undefined
    : SESSION_TRAJECTORY[offer.property].stated(offer.value);
}

Deno.test("an offer proposes what the session already carries", () => {
  const e = engineFor(looseDoc());
  e.setSessionKeyframe("s1", "state", 1000, "draining");
  const offers = trajectoryInsertOffers(e, "s1", 2000, SESSION_PROPERTIES);
  assertEquals(valueOf(offers, "state"), "draining");
  // The attached end proposes the peer that is on it; nothing has to
  // be invented, and inserting says the same thing at a new moment.
  assertEquals(valueOf(offers, "a"), "alice");
});

Deno.test("a loose end proposes a peer the document declares", () => {
  const e = engineFor(looseDoc());
  const offers = trajectoryInsertOffers(e, "s1", 2000, SESSION_PROPERTIES);
  const proposed = valueOf(offers, "b");
  assert(proposed !== undefined, "the loose end offered nothing to attach");
  assert(
    e.doc.entities?.peers?.[proposed] !== undefined,
    `the loose end proposed ${proposed}, which is not a peer`,
  );
});

Deno.test("with no peers, only the state can be stated", () => {
  // The write refuses an end attached to a peer that is not there, so
  // offering the row would be offering a gesture that fails. The
  // state is still offerable: a session always has one.
  const e = engineFor(peerlessDoc());
  const offers = trajectoryInsertOffers(e, "s1", 2000, SESSION_PROPERTIES);
  assertEquals(offers.map((o) => o.property), ["state"]);
  assertEquals(valueOf(offers, "state"), "open");
});

Deno.test("an offer is a value the write actually accepts", () => {
  // The peer lane learned this the hard way: an insert that proposes
  // a value its own write refuses raises where a row should appear.
  const e = engineFor(looseDoc());
  for (
    const offer of trajectoryInsertOffers(e, "s1", 2000, SESSION_PROPERTIES)
  ) {
    e.setSessionKeyframe("s1", offer.property, 2000, offer.value);
    const def = e.doc.entities!.sessions!["s1"]!;
    const track = def.keyframes?.[offer.property];
    const stored = track?.find((kf) => kf.t === 2000)?.value;
    // Both sides are in the property's value channel now, so the whole
    // value is compared: an end's insert stores the pair it offered, and
    // an insert that dropped what backed the attachment would show here.
    assertEquals(
      stored,
      SESSION_TRAJECTORY[offer.property].parse(offer.value),
      `${offer.property}: what the insert offered was not stored`,
    );
  }
});

Deno.test("an offer over an attributed end restates what backed it", () => {
  // An insert says what the session already carries at the playhead. An
  // end carries a peer AND what put them there, so an offer that named
  // only the peer would have the new moment quietly unsay a signed
  // handoff — the recording holds that word, so Build has to keep it.
  const e = engineFor(looseDoc());
  e.setSessionKeyframe("s1", "b", 1000, {
    peer: "bob",
    attributedBy: "verified-handoff",
  });
  const offers = trajectoryInsertOffers(e, "s1", 2000, SESSION_PROPERTIES);
  assertEquals(offers.find((o) => o.property === "b")?.value, {
    peer: "bob",
    attributedBy: "verified-handoff",
  });
});
