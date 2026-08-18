/**
 * The world materializer is the state reconciler: at any t the ECS
 * world must hold exactly the entities alive then, carrying the
 * values they had then. These tests cover the reconcile half — what
 * happens to an entity the world ALREADY holds when the doc's view
 * of time moves — because that is the half a live feed exercises
 * every tick and a fresh seek hides.
 */

import { assert, assertEquals } from "@std/assert";
import { materializeWorldAt } from "./world-materializer.ts";
import type { TimelineDocument } from "../timeline.ts";
import { createWorld, findEndpoint, findPeer, findSession, type GameWorld } from "../world.ts";
import { explicitBound, implicitBound } from "../temporal/bound.ts";
import { attachedEndpoint, sessionEndpoint } from "../../schema/session-end.ts";

const eternal = {
  start: explicitBound(0),
  duration: implicitBound(0),
};

function docWithPeer(
  keyframes?: {
    label?: { t: number; value: string }[];
    profile?: { t: number; value: string }[];
  },
): TimelineDocument {
  return {
    id: "materialize-test",
    duration: 100,
    entities: {
      peers: {
        "127.0.0.1:0": {
          profile: "pancake",
          label: "127.0.0.1:0",
          timing: eternal,
          ...(keyframes ? { keyframes } : {}),
        },
      },
    },
  };
}

Deno.test("a peer already on stage takes the name its label track states", () => {
  const doc = docWithPeer({ label: [{ t: 50, value: "carol" }] });
  const world = createWorld();

  materializeWorldAt(world, doc, 10);
  const before = findPeer(world, "127.0.0.1:0");
  assert(before !== undefined, "the peer is alive at t=10");
  assertEquals(before.peer.label, "127.0.0.1:0");

  // The same entity, no reset in between — this is the live path:
  // an annotation lands, the projection writes the keyframe, and
  // the next tick materializes over the world it already built.
  materializeWorldAt(world, doc, 60);
  const after = findPeer(world, "127.0.0.1:0");
  assert(after !== undefined, "the peer is still alive at t=60");
  assertEquals(after.peer.label, "carol");
  assertEquals(
    after,
    before,
    "relabeling reuses the entity, it does not respawn",
  );
});

Deno.test("scrubbing back past a label keyframe restores the earlier name", () => {
  const doc = docWithPeer({ label: [{ t: 50, value: "carol" }] });
  const world = createWorld();

  materializeWorldAt(world, doc, 60);
  assertEquals(findPeer(world, "127.0.0.1:0")?.peer.label, "carol");

  materializeWorldAt(world, doc, 10);
  assertEquals(findPeer(world, "127.0.0.1:0")?.peer.label, "127.0.0.1:0");
});

Deno.test("a peer with no label track keeps the name it joined under", () => {
  const doc = docWithPeer();
  const world = createWorld();

  materializeWorldAt(world, doc, 10);
  materializeWorldAt(world, doc, 90);
  assertEquals(findPeer(world, "127.0.0.1:0")?.peer.label, "127.0.0.1:0");
});

Deno.test("a peer already on stage takes the profile its track says", () => {
  // The sibling of the label case: a live feed can learn what a
  // partner runs after the session opened, and the stage colors the
  // peer by its profile — so the change has to reach the entity the
  // world already holds.
  const doc = docWithPeer({ profile: [{ t: 50, value: "goblins" }] });
  const world = createWorld();

  materializeWorldAt(world, doc, 10);
  assertEquals(findPeer(world, "127.0.0.1:0")?.peer.profile, "pancake");

  materializeWorldAt(world, doc, 60);
  assertEquals(findPeer(world, "127.0.0.1:0")?.peer.profile, "goblins");

  // And scrubbing back restores what it was known as then.
  materializeWorldAt(world, doc, 10);
  assertEquals(findPeer(world, "127.0.0.1:0")?.peer.profile, "pancake");
});

Deno.test("a session already on stage takes the state its track says", () => {
  // The sibling reconcile this module has always had, pinned beside
  // the peer one so the two stay symmetric.
  const doc: TimelineDocument = {
    id: "materialize-session-test",
    duration: 100,
    entities: {
      peers: {
        alice: { profile: "pancake", timing: eternal },
        bob: { profile: "pancake", timing: eternal },
      },
      sessions: {
        s1: {
          a: attachedEndpoint("alice"),
          b: attachedEndpoint("bob"),
          codec: "syrup",
          captpVersion: "v1_0",
          initialState: "negotiating",
          timing: eternal,
          keyframes: { state: [{ t: 50, value: "open" }] },
        },
      },
    },
  };
  const world = createWorld();

  materializeWorldAt(world, doc, 10);
  assertEquals(findSession(world, "s1")?.session.state, "negotiating");
  materializeWorldAt(world, doc, 60);
  assertEquals(findSession(world, "s1")?.session.state, "open");
});

Deno.test("a session already on stage attaches its loose end to a peer", () => {
  // The reconcile the endpoint tracks exist for. A session runs with one end
  // carrying only a claim; something backs the claim and the end attaches.
  // The SAME session entity keeps its id and its other end. Respawning it
  // would be the visible half of claiming the network closed something.
  const doc: TimelineDocument = {
    id: "materialize-endpoint-test",
    duration: 100,
    entities: {
      peers: {
        bob: { profile: "pancake", timing: eternal },
        alice: {
          profile: "pancake",
          designator: "127.0.0.1:9002",
          timing: eternal,
        },
      },
      sessions: {
        w1: {
          a: attachedEndpoint("bob"),
          b: sessionEndpoint({ designator: "127.0.0.1:9002" }),
          codec: "syrup",
          captpVersion: "v1_0",
          initialState: "open",
          timing: eternal,
          keyframes: { b: [{ t: 50, value: { peer: "alice" } }] },
        },
      },
    },
  };
  const world = createWorld();

  materializeWorldAt(world, doc, 10);
  const before = findSession(world, "w1");
  assert(before !== undefined, "the session is on stage at t=10");
  assertEquals(before.endpoints, { a: "bob", b: "w1::b" });
  assert(
    findEndpoint(world, "w1::b") !== undefined,
    "the loose end is drawn while it is loose",
  );

  materializeWorldAt(world, doc, 60);
  const after = findSession(world, "w1");
  assert(after !== undefined, "the session is still on stage at t=60");
  assertEquals(after.endpoints, { a: "bob", b: "alice" });
  assertEquals(
    after,
    before,
    "attaching an end reuses the session entity, it does not respawn",
  );
  assertEquals(
    findEndpoint(world, "w1::b"),
    undefined,
    "the placeholder goes when the end attaches",
  );

  // And scrubbing back shows what the viewer knew then.
  materializeWorldAt(world, doc, 10);
  assertEquals(findSession(world, "w1")?.endpoints, { a: "bob", b: "w1::b" });
});

Deno.test("a peer that learns its designator carries it on stage", () => {
  // A producer that speaks for a peer later states the durable name it
  // answers to, and the projection records it on the definition. The world
  // entity has to learn it too: a claim is matched against a peer's
  // designator, so a peer whose entity never got one is a peer no session
  // end's claim can ever name.
  const doc: TimelineDocument = {
    id: "materialize-designator-test",
    duration: 100,
    entities: {
      peers: { alice: { profile: "pancake", timing: eternal } },
    },
  };
  const world = createWorld();
  materializeWorldAt(world, doc, 10);
  assertEquals(findPeer(world, "alice")?.peer.designator, undefined);

  const learned: TimelineDocument = {
    ...doc,
    entities: {
      peers: {
        alice: {
          profile: "pancake",
          designator: "127.0.0.1:9001",
          timing: eternal,
        },
      },
    },
  };
  materializeWorldAt(world, learned, 60);
  assertEquals(
    findPeer(world, "alice")?.peer.designator,
    "127.0.0.1:9001",
    "the world entity never learned the designator",
  );
});

// ── The reconciler's own contract ──

/** Everything a materialized world holds, in a form two worlds compare on.
 *
 *  Positions are left out: this module does not write them, and the layout
 *  that does runs afterwards. */
function contentsOf(world: GameWorld): string[] {
  const rows: string[] = [];
  for (const e of world.with("peer")) {
    rows.push(`peer ${JSON.stringify(e.peer)}`);
  }
  for (const e of world.with("endpoint")) {
    rows.push(`endpoint ${JSON.stringify(e.endpoint)}`);
  }
  for (const e of world.with("session", "endpoints")) {
    rows.push(
      `session ${JSON.stringify(e.session)} ${JSON.stringify(e.endpoints)}`,
    );
  }
  for (const e of world.with("messageInFlight")) {
    rows.push(`message ${JSON.stringify(e.messageInFlight)}`);
  }
  return rows.sort();
}

/**
 * The reconciler's whole promise, as one assertion: a world materialized onto
 * what it already held holds exactly what a world built from nothing holds.
 *
 * It is the only check that covers every field at once, and it is the shape
 * the app actually diverges on. Live never rebuilds the world, so it only ever
 * takes the reconcile arm; replay resets and only ever takes the create arm. A
 * value written where an entity is created and never written again is
 * therefore right in one of the two and stale in the other, and no test of one
 * arm alone can see it.
 */
function assertReconciles(
  what: string,
  world: GameWorld,
  doc: TimelineDocument,
  t: number,
): void {
  materializeWorldAt(world, doc, t);
  const fresh = createWorld();
  materializeWorldAt(fresh, doc, t);
  assertEquals(
    contentsOf(world),
    contentsOf(fresh),
    `${what}: the reconciled world and a fresh one are two pictures`,
  );
}

/** One of everything, so the walk below has each kind to reconcile. */
function fullDoc(edits: {
  codec?: string;
  captpVersion?: string;
  claim?: string;
  messageLabel?: string;
} = {}): TimelineDocument {
  return {
    id: "reconcile-test",
    duration: 100,
    entities: {
      peers: {
        alice: { profile: "pancake", label: "alice", timing: eternal },
        bob: { profile: "pancake", label: "bob", timing: eternal },
      },
      sessions: {
        s1: {
          a: attachedEndpoint("alice"),
          b: sessionEndpoint({ designator: edits.claim ?? "127.0.0.1:9002" }),
          codec: edits.codec ?? "syrup",
          captpVersion: edits.captpVersion ?? "v1_0",
          initialState: "open",
          timing: eternal,
        },
      },
      messages: {
        m1: {
          sessionId: "s1",
          from: "alice",
          to: "s1::b",
          label: edits.messageLabel ?? "op:deliver",
          timing: { start: explicitBound(10), duration: explicitBound(80) },
        },
      },
    },
  } as unknown as TimelineDocument;
}

Deno.test("a session already on stage takes the codec and version it now states", () => {
  // Both are written where the session entity is created. An author who
  // corrects either one, or a producer that reports a session before its
  // handshake settles, leaves the world holding the value it was drawn with.
  const world = createWorld();
  materializeWorldAt(world, fullDoc(), 20);
  assertReconciles(
    "codec and version",
    world,
    fullDoc({ codec: "capnp", captpVersion: "next" }),
    20,
  );
});

Deno.test("a loose end already on stage takes the claim it now carries", () => {
  // What an end claims is what the reader selects it to find out, and it is
  // written where the end is created.
  const world = createWorld();
  materializeWorldAt(world, fullDoc(), 20);
  assertReconciles(
    "the claim on an end",
    world,
    fullDoc({ claim: "[::1]:9" }),
    20,
  );
});

Deno.test("a message already in flight takes the label it now carries", () => {
  const world = createWorld();
  materializeWorldAt(world, fullDoc(), 20);
  assertReconciles(
    "a message label",
    world,
    fullDoc({ messageLabel: "op:abort" }),
    20,
  );
});

Deno.test("walking a world through a document lands where building it fresh does", () => {
  // The reconciler over one unchanging document, walked forward and back. It
  // is the cheapest form of the live-versus-replay differential and it lives
  // here because this is the function the difference is made in.
  const doc = fullDoc();
  const world = createWorld();
  for (const t of [0, 20, 50, 95, 50, 20, 0, 100]) {
    assertReconciles(`walking to t=${t}`, world, doc, t);
  }
});
