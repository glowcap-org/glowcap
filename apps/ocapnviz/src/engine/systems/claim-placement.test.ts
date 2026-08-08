/**
 * Where a loose end is placed, which is the one thing separating a loose end
 * that claims a peer on stage from every other loose end.
 *
 * A claim's destination is the peer it names, so its session is solved as if
 * the end were already there and the end is then sat on the resulting edge,
 * `CLAIM_LEAN` of the way along. Every other loose end — one naming nobody the
 * stage draws, one naming nothing at all — has no destination and is an
 * ordinary body in the solve.
 *
 * The arithmetic is testable without a canvas, so it is tested here; the
 * drawing that reads the same distinction is held in `src/render`.
 */

import { assert, assertAlmostEquals, assertEquals } from "@std/assert";
import { createWorld, findNode, type GameWorld, type Vec2 } from "../world.ts";
import { TimelineDocument, type TimelineEvent } from "../timeline.ts";
import { materializeWorldAt } from "./world-materializer.ts";
import { projectFromObservations } from "../temporal/project-from-observations.ts";
import { Engine } from "../engine.ts";
import {
  CLAIM_LEAN,
  DEFAULT_LAYOUT_CONFIG,
  KeyframeLayoutSystem,
  type LayoutConfig,
} from "./keyframe-layout-system.ts";
import { claimedPeerByEnd } from "../claims.ts";
import {
  haloRadius,
  LOOSE_END_CLAIMING,
  NODE_RADIUS,
} from "../../render/draw-helpers.ts";
import {
  bezierAt,
  claimTargets,
  computeSessionBundles,
  curveBetween,
  drawnSessionCurve,
} from "../session-geometry.ts";
import { scenarios } from "../../fixtures/index.ts";
import {
  endpointStageId,
  SESSION_SIDES,
  type SessionEndpoint,
  type SessionSide,
} from "../../schema/topology.ts";

// d3-force leaves a d3-timer handle behind under Deno; same workaround as
// `keyframe-layout-system.test.ts`.
function layoutTest(name: string, fn: () => void): void {
  Deno.test({ name, sanitizeOps: false, sanitizeResources: false, fn });
}

const ALICE_DESIGNATOR = "tcp://10.0.0.1:9001";
const BOB_DESIGNATOR = "tcp://10.0.0.2:9001";

/** How far from a peer a placed claim reads as being *about* that peer;
 *  anything past this is a node the layout placed on its own account. Both
 *  populations are asserted below, so a retune that moved either goes red
 *  rather than quietly passing, and the last test measures the recordings'
 *  own edges against it. */
const NEAR_PEER = 200;

/** Centre distance at which a claim's body touches a peer's: the sum of the
 *  two half-widths, read off the styles that draw them. Retuning either one
 *  moves this assertion instead of invalidating it. */
const BODIES_TOUCH = NODE_RADIUS + LOOSE_END_CLAIMING.radius;

/** The daylight `CLAIM_LEAN` is chosen to leave: between the claim's body and
 *  the peer's, about a node's width of empty space. It is what makes the claim
 *  read as short of the peer rather than against it, and it is the reason the
 *  fraction is two thirds. */
const CLAIM_DAYLIGHT = NODE_RADIUS;

/** The same daylight measured between the two focus RINGS, which stand
 *  further out than the bodies they circle and so have less room to play
 *  with. A claim's own body is the unit here: rings that stay that far apart
 *  read as two rings, and rings closer than that read as one shape. */
const RING_DAYLIGHT = LOOSE_END_CLAIMING.radius;

/** A document with these observations and nothing else. Parsing derives the
 *  identity entries, so the layout reads the same doc a loaded file gives it. */
function docOf(events: TimelineEvent[]): TimelineDocument {
  return TimelineDocument.parse({
    id: "claim-placement",
    duration: 1000,
    events,
  });
}

function joined(peerId: string, designator?: string): TimelineEvent {
  return joinedAt(0, peerId, designator);
}

/** The same join at a stated moment, for the documents whose point is that two
 *  peers were never on the stage at once. */
function joinedAt(
  t: number,
  peerId: string,
  designator?: string,
): TimelineEvent {
  return {
    id: `join-${peerId}`,
    t,
    kind: "peer-joined",
    peerId,
    profile: "pancake",
    ...(designator !== undefined ? { designator } : {}),
  } as TimelineEvent;
}

type End = { peer?: string; designator?: string; attributedBy?: string };

/** One session whose near end is `carol` — a reporting producer's own end is
 *  always attributed — and whose far end is whatever is handed in. */
function opened(sessionId: string, b: End): TimelineEvent {
  return between(
    sessionId,
    { peer: "carol", attributedBy: "self-reported" },
    b,
  );
}

/** One session between two ends stated outright, for the cases where both
 *  matter. */
function between(sessionId: string, a: End, b: End): TimelineEvent {
  return {
    id: `open-${sessionId}`,
    t: 0,
    kind: "session-opened",
    sessionId,
    a,
    b,
    codec: "syrup",
    captpVersion: "v1_0",
  } as TimelineEvent;
}

/** Every node's position after materializing and running the layout — what
 *  the stage would draw, peers and loose ends alike. */
function placed(
  doc: TimelineDocument,
  config: LayoutConfig = DEFAULT_LAYOUT_CONFIG,
): Map<string, Vec2> {
  const world: GameWorld = createWorld();
  materializeWorldAt(world, doc, 50);
  new KeyframeLayoutSystem(doc, config).update(world, 50);
  const at = new Map<string, Vec2>();
  for (const e of world.with("peer", "position")) at.set(e.peer.id, e.position);
  for (const e of world.with("endpoint", "position")) {
    at.set(e.endpoint.id, e.position);
  }
  return at;
}

function dist(a: Vec2, b: Vec2): number {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

/** Where `p` sits on the line through `from` and `toward`: how far along as a
 *  fraction of that segment, and how far off it. A claim on its session's
 *  edge is `{ along: CLAIM_LEAN, off: 0 }`. */
function onSegment(
  p: Vec2,
  from: Vec2,
  toward: Vec2,
): { along: number; off: number } {
  const dx = toward.x - from.x;
  const dy = toward.y - from.y;
  const len = Math.hypot(dx, dy);
  return {
    along: ((p.x - from.x) * dx + (p.y - from.y) * dy) / (len * len),
    off: Math.abs((p.x - from.x) * dy - (p.y - from.y) * dx) / len,
  };
}

layoutTest("a claim sits at CLAIM_LEAN along its session's edge", () => {
  // The whole design in one assertion. The session was solved as if its far
  // end were already Alice, so the edge points at Alice; the claim rides that
  // edge and stops a third short of her.
  const at = placed(docOf([
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    opened("s", { designator: ALICE_DESIGNATOR }),
  ]));
  const alice = at.get("alice");
  const carol = at.get("carol");
  const claim = at.get("s::b");
  assert(alice !== undefined && carol !== undefined);
  assert(claim !== undefined, "the loose end was not drawn");
  const on = onSegment(claim, carol, alice);
  assertAlmostEquals(on.along, CLAIM_LEAN, 1e-9, `claim sat ${on.along} along`);
  assertAlmostEquals(on.off, 0, 1e-9, `claim sat ${on.off} off the edge`);
  // And the reading that fraction buys: near enough to be about Alice, far
  // enough that the two bodies do not touch.
  assert(dist(claim, alice) < NEAR_PEER);
  assert(
    dist(claim, alice) > BODIES_TOUCH,
    "the claim body reached the peer's",
  );
});

layoutTest("a peer is matched on the name it answers to, not its id", () => {
  // The claim is a wire name and the peer id is the viewer's handle, so a
  // claim spelling the id is a claim about a name nobody on the wire uses.
  const at = placed(docOf([
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    opened("s", { designator: "alice" }),
  ]));
  const alice = at.get("alice");
  const loose = at.get("s::b");
  assert(alice !== undefined && loose !== undefined);
  assert(
    dist(loose, alice) > NEAR_PEER,
    "a claim spelling a peer id was placed on that peer",
  );
});

layoutTest("a claim naming nobody the stage draws stands on its own", () => {
  // No destination, so the end is an ordinary
  // body in the solve and takes the solver's own separation, which is a
  // node's width and then some rather than a claim's third of an edge.
  const at = placed(docOf([
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    opened("s", { designator: "tcp://198.51.100.7:9001" }),
  ]));
  const alice = at.get("alice");
  const carol = at.get("carol");
  const loose = at.get("s::b");
  assert(alice !== undefined && carol !== undefined);
  assert(loose !== undefined, "the loose end was not drawn");
  const nearest = Math.min(dist(loose, alice), dist(loose, carol));
  assert(
    nearest > NEAR_PEER,
    `a stranger's claim landed ${nearest} from a peer, close enough to read as being about it`,
  );
});

layoutTest("an end with no claim at all stands on its own", () => {
  const at = placed(docOf([
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    opened("s", {}),
  ]));
  const alice = at.get("alice");
  const loose = at.get("s::b");
  assert(alice !== undefined);
  assert(loose !== undefined, "the loose end was not drawn");
  assert(
    dist(loose, alice) > NEAR_PEER,
    "an end claiming nothing was placed on a peer",
  );
});

layoutTest("a claim two peers answer to is placed on neither", () => {
  // A designator two peers hold names neither of them in particular, and
  // putting the claim on whichever was indexed first would assert a
  // relationship the document does not support.
  const at = placed(docOf([
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    joined("alias", ALICE_DESIGNATOR),
    opened("s", { designator: ALICE_DESIGNATOR }),
  ]));
  const alice = at.get("alice");
  const alias = at.get("alias");
  const loose = at.get("s::b");
  assert(alice !== undefined && alias !== undefined);
  assert(loose !== undefined, "the loose end was not drawn");
  const nearest = Math.min(dist(loose, alice), dist(loose, alias));
  assert(
    nearest > NEAR_PEER,
    "an ambiguous claim was placed on one of the two",
  );
});

layoutTest("an author's placement of a loose end wins", () => {
  const doc = docOf([
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    opened("s", { designator: ALICE_DESIGNATOR }),
  ]);
  // The pin lives on the session, the only thing that outlives the end. An
  // author who put the end somewhere meant it, so the pin beats the lean and
  // the end is a solved body again, holding its own position.
  const session = doc.entities?.sessions?.["s"];
  assert(session !== undefined);
  session.endpointPosition = { b: { x: 1234, y: -900 } };
  const loose = placed(doc).get("s::b");
  assert(loose !== undefined);
  assertEquals({ x: loose.x, y: loose.y }, { x: 1234, y: -900 });
});

layoutTest("attribution moves the end and nothing else", () => {
  // Why the placement is worth having, and the strongest claim this file
  // makes. The session was solved to Alice while the end was still only
  // claiming to be her, so backing the claim changes no force in the graph:
  // every peer stays where it was, to the last bit. The placeholder is removed
  // and the edge's end is on Alice, who has not moved.
  const claiming = docOf([
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    opened("s", { designator: ALICE_DESIGNATOR }),
  ]);
  const attributed = docOf([
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    opened("s", {
      peer: "alice",
      designator: ALICE_DESIGNATOR,
      attributedBy: "authenticated-transport",
    }),
  ]);
  const before = placed(claiming);
  const after = placed(attributed);
  assertEquals(
    after.has("s::b"),
    false,
    "the placeholder outlived the attribution that replaced it",
  );
  for (const peerId of ["alice", "carol"]) {
    const was = before.get(peerId);
    const now = after.get(peerId);
    assert(was !== undefined && now !== undefined);
    assertEquals(
      { x: now.x, y: now.y },
      { x: was.x, y: was.y },
      `${peerId} moved when the end was attributed`,
    );
  }
});

layoutTest("a claim at each end takes its own third of the wire", () => {
  // Neither end has a solved position of its own, so each contributes the
  // peer IT names and the segment is the one between those two peers. The
  // lookup is one step deep by construction — a claim never reads another
  // claim's position — so the two resolve together instead of chasing each
  // other.
  const at = placed(docOf([
    joined("alice", ALICE_DESIGNATOR),
    joined("bob", BOB_DESIGNATOR),
    between("s", { designator: ALICE_DESIGNATOR }, {
      designator: BOB_DESIGNATOR,
    }),
  ]));
  const alice = at.get("alice");
  const bob = at.get("bob");
  const towardAlice = at.get("s::a");
  const towardBob = at.get("s::b");
  assert(alice !== undefined && bob !== undefined);
  assert(towardAlice !== undefined && towardBob !== undefined);
  assertAlmostEquals(
    onSegment(towardAlice, bob, alice).along,
    CLAIM_LEAN,
    1e-9,
  );
  assertAlmostEquals(onSegment(towardBob, alice, bob).along, CLAIM_LEAN, 1e-9);
  // What is left of the wire between them, so the two read as two things.
  assertAlmostEquals(
    dist(towardAlice, towardBob),
    dist(alice, bob) * (2 * CLAIM_LEAN - 1),
    1e-9,
  );
});

layoutTest(
  "a session claiming the peer at its own far end leans nowhere",
  () => {
    // The degenerate segment: the end claims to be Alice and Alice is already
    // sitting at the other end of this very session. There is no direction to
    // lean in, so the end is an ordinary solved body — which is also what stops
    // the resolution from having to ask what a zero-length segment means.
    const at = placed(docOf([
      joined("alice", ALICE_DESIGNATOR),
      between("s", { peer: "alice", attributedBy: "self-reported" }, {
        designator: ALICE_DESIGNATOR,
      }),
    ]));
    const alice = at.get("alice");
    const loose = at.get("s::b");
    assert(alice !== undefined && loose !== undefined);
    assert(
      dist(loose, alice) > BODIES_TOUCH,
      "the end landed on the peer its own session already reaches",
    );
  },
);

layoutTest("claims on one peer arrive from their own directions", () => {
  // What answers the crowd. Two claims about Alice, one on Bob's wire and one
  // on Carol's, ride two different edges and so land in two different places
  // without anything arranging them.
  const at = placed(docOf([
    joined("carol"),
    joined("bob"),
    joined("alice", ALICE_DESIGNATOR),
    opened("s1", { designator: ALICE_DESIGNATOR }),
    between("s2", { peer: "bob", attributedBy: "self-reported" }, {
      designator: ALICE_DESIGNATOR,
    }),
  ]));
  const first = at.get("s1::b");
  const second = at.get("s2::b");
  assert(first !== undefined && second !== undefined);
  assert(
    dist(first, second) > 60,
    `two claims from different peers landed ${dist(first, second)} apart`,
  );
});

layoutTest("two claims on one pair each ride their own lane", () => {
  // These used to land on the same pixel, and this test recorded that as the
  // limit of the rule: two sessions between one pair describe one segment, so
  // two claims leaning along it sat on one point and a reader saw one shape
  // where there were two ends.
  //
  // It also argued the fix was not in the bundling, because a bundle offset
  // moves a session's control point and never its endpoints. That was true
  // only while a claim was placed on the straight chord between the two. A
  // claim placed on the CURVE rides the bow, so the same offset that fans the
  // two arcs apart now carries their claims apart with them, and the reader
  // sees two ends because there are two.
  const at = placed(docOf([
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    opened("s1", { designator: ALICE_DESIGNATOR }),
    opened("s2", { designator: ALICE_DESIGNATOR }),
  ]));
  const first = at.get("s1::b");
  const second = at.get("s2::b");
  assert(first !== undefined && second !== undefined);
  assert(
    dist(first, second) > LOOSE_END_CLAIMING.radius,
    `two claims on one pair landed ${dist(first, second)} apart, close ` +
      `enough to read as one end`,
  );
});

layoutTest("authored mode places a claim on its edge too", () => {
  // Authored mode honors the author for every node it can, and a loose end is
  // not a node the author named — the session states a claim, and the claim
  // states where the end belongs. One rule, both modes.
  const doc = docOf([
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    opened("s", { designator: ALICE_DESIGNATOR }),
  ]);
  const peers = doc.entities?.peers;
  assert(peers !== undefined);
  peers["carol"]!.position = { x: -300, y: 0 };
  peers["alice"]!.position = { x: 300, y: 0 };
  const at = placed(doc, { ...DEFAULT_LAYOUT_CONFIG, mode: "authored" });
  const claim = at.get("s::b");
  assert(claim !== undefined, "authored mode left the claim unplaced");
  // Almost, not exactly: a lone session is a singleton bundle whose curve
  // degenerates to its own chord, so this is the straight lean computed
  // through the Bezier and lands within float residue of it.
  assertAlmostEquals(claim.x, -300 + 600 * CLAIM_LEAN, 1e-9);
  assertAlmostEquals(claim.y, 0, 1e-9);
});

/** One session edge as a claim would ride it: how long the segment is, and,
 *  when one of the ends IS a claim, how far the drawn claim ended up from the
 *  peer it names. */
type BundledEdge = { length: number; drawnFromPeer: number | undefined };

/** Every session edge the shipped recordings settle on, in every era they
 *  settle it: the population `CLAIM_LEAN` was chosen against.
 *
 *  Each end resolves to the node its session is solved against — the peer
 *  attached to it, or the peer its claim names — because that is the segment
 *  the lean is a fraction of. Reading an end's own node id instead would
 *  measure a claim's already-leaned position and call it an edge. An end that
 *  resolves to nobody rides no edge at all: it is an ordinary body in the
 *  solve, which is the case the tests above cover. */
function bundledSessionEdges(): BundledEdge[] {
  const edges: BundledEdge[] = [];
  for (const doc of scenarios) {
    // Read the one authority rather than re-deriving it: a second
    // spelling here would agree with the layout only until one of them
    // changed, which is the whole reason `claims.ts` exists.
    const claimed = claimedPeerByEnd(doc);
    const solvedNode = (
      sessionId: string,
      side: SessionSide,
      end: SessionEndpoint,
    ): string | undefined =>
      end.peer ?? claimed.get(endpointStageId(sessionId, side));
    const system = new KeyframeLayoutSystem(doc, {
      ...DEFAULT_LAYOUT_CONFIG,
      mode: doc.layoutMode ?? DEFAULT_LAYOUT_CONFIG.mode,
    });
    for (
      const [sessionId, def] of Object.entries(doc.entities?.sessions ?? {})
    ) {
      const a = solvedNode(sessionId, "a", def.a);
      const b = solvedNode(sessionId, "b", def.b);
      if (a === undefined || b === undefined || a === b) continue;
      for (const keyframe of system.keyframes) {
        const from = keyframe.layout.get(a);
        const toward = keyframe.layout.get(b);
        if (!from || !toward) continue;
        // Where the claim was actually drawn, for the one end in this
        // document that is a claim rather than an attachment.
        let drawn: number | undefined;
        for (const side of SESSION_SIDES) {
          if (def[side].peer !== undefined) continue;
          const at = keyframe.layout.get(endpointStageId(sessionId, side));
          const named = keyframe.layout.get(side === "a" ? a : b);
          if (at && named) drawn = dist(at, named);
        }
        edges.push({
          length: dist(from, toward),
          drawnFromPeer: drawn,
        });
      }
    }
  }
  return edges;
}

/** How far a claim leaning `lean` along an edge of `length` stops short of the
 *  peer's body: the gap a reader actually sees between the two dots. */
function daylightOn(length: number, lean: number): number {
  return length * (1 - lean) - BODIES_TOUCH;
}

/** The same gap measured between the two FOCUS RINGS rather than the two
 *  bodies, which is what a reader sees the moment either one is picked.
 *
 *  At 100% zoom, which is the scale the fraction was chosen at. A ring holds its
 *  screen size as the camera pulls back while the bodies shrink with it, so the
 *  gap measured here is the widest the reader ever gets; `haloRadius` says so at
 *  the declaration. */
const RING_SCALE_AT_100_PERCENT = 1;

function ringGapOn(length: number, lean: number): number {
  return length * (1 - lean) -
    haloRadius(NODE_RADIUS, RING_SCALE_AT_100_PERCENT) -
    haloRadius(LOOSE_END_CLAIMING.radius, RING_SCALE_AT_100_PERCENT);
}

layoutTest(
  "CLAIM_LEAN leaves daylight on every edge the recordings settle",
  () => {
    // The argument for the fraction, measured where it was made. `CLAIM_LEAN` is
    // two thirds because of how far apart the shipped recordings settle a
    // session's two ends, so a fixture that moves its peers moves the reading —
    // and this is where that goes red instead of quietly becoming untrue.
    const edges = bundledSessionEdges();
    assert(edges.length > 0, "no bundled session edge was measured");
    let drawnClaims = 0;
    for (const edge of edges) {
      const toPeer = edge.length * (1 - CLAIM_LEAN);
      const daylight = daylightOn(edge.length, CLAIM_LEAN);
      // The same daylight the ring comparison below argues, stated per edge and
      // between the bodies rather than between the rings. It is the weaker of
      // the two, since a ring stands further out than the body it circles, and
      // it is kept because it is the claim in the plainest terms: no claim on
      // any edge any recording settles ends up against the peer it names.
      assert(
        daylight >= CLAIM_DAYLIGHT,
        `a claim on a ${edge.length.toFixed(0)}-unit edge stops ${
          daylight.toFixed(0)
        } short of the peer, inside the ${CLAIM_DAYLIGHT} of daylight the lean is for`,
      );
      assert(
        toPeer < NEAR_PEER,
        `a claim on a ${
          edge.length.toFixed(0)
        }-unit edge landed far enough out to read as a node of its own`,
      );
      // A claim the recordings actually draw sits where that arithmetic says,
      // which is what makes the band above a measurement of the picture rather
      // than of a segment nothing rides.
      if (edge.drawnFromPeer === undefined) continue;
      drawnClaims += 1;
      assertAlmostEquals(edge.drawnFromPeer, toPeer, 1e-6);
    }
    assert(drawnClaims > 0, "no shipped recording draws a claim at all");
    // And why it is two thirds rather than three quarters. Selecting a claim
    // and selecting the peer it names each draw a focus ring, and the two
    // readings are only separate readings while the rings are. The argument is
    // one comparison against one quantity, `RING_DAYLIGHT`: on the shortest
    // edge the recordings settle, two thirds keeps a claim's own body of
    // daylight between the rings and three quarters does not.
    //
    // Both readings come off the shipped recordings, so both move when a
    // fixture moves its peers. That is the point — the fraction was chosen
    // against these edges — but it also means a retune of `nodeSpacing` or
    // `linkDistance` can turn this red with nothing about `CLAIM_LEAN` having
    // changed. Read the two distances in the message before reaching for the
    // fraction.
    const shortest = Math.min(...edges.map((e) => e.length));
    assert(
      ringGapOn(shortest, CLAIM_LEAN) >= RING_DAYLIGHT,
      `the claim's ring comes within ${
        ringGapOn(shortest, CLAIM_LEAN).toFixed(0)
      } of the peer's on the shortest edge the recordings settle, which is ${
        shortest.toFixed(0)
      } long`,
    );
    assert(
      ringGapOn(shortest, 3 / 4) < RING_DAYLIGHT,
      `three quarters leaves ${
        ringGapOn(shortest, 3 / 4).toFixed(0)
      } between the rings on that same edge, which already clears a claim's own body, so the fraction is arbitrary`,
    );
  },
);

layoutTest("pinning a claim moves the claim and nothing else", () => {
  // The pin says where the dot goes. It does not say what the session is
  // solved against, and letting it say both would mean a nudge of a claim
  // pulled the whole picture: the session's link would come off Alice and
  // back onto the claim, and Alice would drift away from Carol with nothing
  // holding her. So the peers are bit-identical either way.
  const events = [
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    opened("s", { designator: ALICE_DESIGNATOR }),
  ];
  const free = placed(docOf(events));
  const pinnedDoc = docOf(events);
  const session = pinnedDoc.entities?.sessions?.["s"];
  assert(session !== undefined);
  session.endpointPosition = { b: { x: 40, y: 70 } };
  const pinned = placed(pinnedDoc);
  assertEquals({ ...pinned.get("s::b") }, { x: 40, y: 70 });
  for (const peerId of ["alice", "carol"]) {
    const a = free.get(peerId);
    const b = pinned.get(peerId);
    assert(a !== undefined && b !== undefined);
    assertEquals(
      { x: b.x, y: b.y },
      { x: a.x, y: a.y },
      `${peerId} moved because a claim was pinned`,
    );
  }
});

layoutTest("the claim sits on the arc its own edge is drawn along", () => {
  // The pair Jim's screenshot showed apart: the claim bulged onto a curve of
  // its own because the edge was built between the far end and the CLAIM's
  // position, which is a different chord and so a different arc. Both are
  // built from one curve now — the one a full session to the claimed peer
  // would take — so the drawn line ends exactly where the claim stands.
  const doc = docOf([
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    // Two sessions on the pair, so the fan is real and the lane is bowed.
    opened("s1", { peer: "alice" }),
    opened("s2", { designator: ALICE_DESIGNATOR }),
  ]);
  const world = createWorld();
  materializeWorldAt(world, doc, 50);
  new KeyframeLayoutSystem(doc).update(world, 50);

  const towards = claimTargets(world, claimedPeerByEnd(doc));
  const bundles = computeSessionBundles(world, towards);
  const bundle = bundles.get("s2");
  assert(bundle !== undefined && bundle.size === 2, "the fan did not form");
  const curve = drawnSessionCurve(
    world,
    "carol",
    "s2::b",
    bundle,
    towards,
    CLAIM_LEAN,
  );
  assert(curve !== null, "the claimed edge had no curve");
  const claim = findNode(world, "s2::b")?.position;
  assert(claim !== undefined, "the claim was not placed");
  // The drawn arc stops AT the claim, rather than beside it.
  assertAlmostEquals(curve.bx, claim.x, 1e-9);
  assertAlmostEquals(curve.by, claim.y, 1e-9);

  // And every point of it lies on the lane a full session to alice would
  // take. This is the whole claim, and the endpoint alone does not make it:
  // an arc built between carol and the claim's own position also ends there,
  // while bulging along a different chord the whole way.
  const alice = findNode(world, "alice")?.position;
  const carol = findNode(world, "carol")?.position;
  assert(alice !== undefined && carol !== undefined);
  const lane = curveBetween("carol", carol, "alice", alice, bundle);
  for (const t of [0.25, 0.5, 0.75, 1]) {
    const drawn = bezierAt(curve, t);
    const onLane = bezierAt(lane, t * CLAIM_LEAN);
    assertAlmostEquals(drawn.x, onLane.x, 1e-9, `x at t=${t} left the lane`);
    assertAlmostEquals(drawn.y, onLane.y, 1e-9, `y at t=${t} left the lane`);
  }
});

layoutTest(
  "a closed session keeps its lane, so the claim beside it keeps its arc",
  () => {
    // One fact, two authorities, and they disagreed the moment a session
    // closed. The world draws a session for as long as its effective range
    // holds — a closed one is drawn faded, not removed — while the layout used
    // to drop it from the era the moment a `session-closed` observation went
    // by. The pair's bundle then had two lanes on screen and one in the solve,
    // so the claim was placed on the straight lane of a one-lane bundle and the
    // arc drawn to it bowed along a different chord.
    const doc = docOf([
      joined("carol"),
      joined("alice", ALICE_DESIGNATOR),
      opened("s1", { peer: "alice" }),
      opened("s2", { designator: ALICE_DESIGNATOR }),
      {
        id: "close-s1",
        t: 40,
        kind: "session-closed",
        sessionId: "s1",
      } as TimelineEvent,
    ]);

    // After the close, and after the transition window has settled.
    const t = 900;
    const world = createWorld();
    materializeWorldAt(world, doc, t);
    new KeyframeLayoutSystem(doc).update(world, t);

    const bundle = computeSessionBundles(
      world,
      claimTargets(world, claimedPeerByEnd(doc)),
    ).get("s2");
    assert(bundle !== undefined, "s2 left the world");
    assertEquals(
      bundle.size,
      2,
      "the closed session left the world, so this test no longer measures anything",
    );

    const curve = drawnSessionCurve(
      world,
      "carol",
      "s2::b",
      bundle,
      claimTargets(world, claimedPeerByEnd(doc)),
      CLAIM_LEAN,
    );
    assert(curve !== null, "the claimed edge had no curve");
    const alice = findNode(world, "alice")?.position;
    const carol = findNode(world, "carol")?.position;
    assert(alice !== undefined && carol !== undefined);
    // Every point of the drawn arc still lies on the lane a full session to
    // alice would take. The endpoint alone proves nothing here: when the two
    // disagree the renderer falls back to an ordinary edge, which also reaches
    // the claim, while bowing along a chord of its own the whole way.
    const lane = curveBetween("carol", carol, "alice", alice, bundle);
    for (const at of [0.25, 0.5, 0.75, 1]) {
      const drawn = bezierAt(curve, at);
      const onLane = bezierAt(lane, at * CLAIM_LEAN);
      assertAlmostEquals(drawn.x, onLane.x, 1e-9, `x at t=${at} left the lane`);
      assertAlmostEquals(drawn.y, onLane.y, 1e-9, `y at t=${at} left the lane`);
    }
  },
);

layoutTest("a pinned claim keeps its edge, and the lane lets go", () => {
  // Dragging a claim pins it, and the layout hands a pinned claim its pin
  // rather than the lean — so the lane it was riding no longer passes
  // through it. The edge stops being that lane's prefix and becomes an
  // ordinary edge to where the author put it, because the one thing that
  // must stay true is that the line reaches the node.
  const doc = docOf([
    joined("carol"),
    joined("alice", ALICE_DESIGNATOR),
    opened("s1", { peer: "alice" }),
    opened("s2", { designator: ALICE_DESIGNATOR }),
  ]);
  const sessions = doc.entities?.sessions;
  assert(sessions !== undefined);
  sessions["s2"]!.endpointPosition = { b: { x: -900, y: 640 } };

  const world = createWorld();
  materializeWorldAt(world, doc, 50);
  new KeyframeLayoutSystem(doc).update(world, 50);

  const claim = findNode(world, "s2::b")?.position;
  assert(claim !== undefined);
  assertAlmostEquals(claim.x, -900, 1e-6, "the pin was not honored");
  assertAlmostEquals(claim.y, 640, 1e-6, "the pin was not honored");

  const bundle = computeSessionBundles(
    world,
    claimTargets(world, claimedPeerByEnd(doc)),
  ).get("s2");
  assert(bundle !== undefined);
  const curve = drawnSessionCurve(
    world,
    "carol",
    "s2::b",
    bundle,
    claimTargets(world, claimedPeerByEnd(doc)),
    CLAIM_LEAN,
  );
  assert(curve !== null, "the pinned claim's edge vanished");
  assertAlmostEquals(curve.bx, claim.x, 1e-9, "the edge missed the claim");
  assertAlmostEquals(curve.by, claim.y, 1e-9, "the edge missed the claim");
});

// ──────── the placement and the drawing resolve claims the same way ────────

/** The three answers that have to agree about one end at one moment: whether
 *  the layout leaned it, whether the frame draws it as a claim, and how the
 *  frame keys its session's lane. */
function readingAt(doc: TimelineDocument, t: number) {
  const world = createWorld();
  materializeWorldAt(world, doc, t);
  const system = new KeyframeLayoutSystem(doc);
  system.update(world, t);
  const towards = claimTargets(world, system.claims);
  return {
    at: (id: string): Vec2 | undefined => findNode(world, id)?.position,
    drawnAsClaim: towards,
    bundles: computeSessionBundles(world, towards),
  };
}

layoutTest(
  "a designator two peers answer to in different eras names neither",
  () => {
    // The two never stand on the stage together, so every moment draws exactly
    // one of them and a resolution asked of the moment would name that one.
    // Asked of the document — where the ambiguity is — it names neither, and
    // that is the answer both surfaces need: the layout refuses to lean the
    // claim, so a frame that resolved it anyway would key this session onto
    // Alice's lane and shove the real session on that pair out of its own.
    const doc = projectFromObservations(docOf([
      joined("carol"),
      joined("alice-home", ALICE_DESIGNATOR),
      between("s-real", { peer: "carol", attributedBy: "self-reported" }, {
        peer: "alice-home",
        attributedBy: "self-reported",
      }),
      opened("s-claim", { designator: ALICE_DESIGNATOR }),
      { id: "home-leaves", t: 400, kind: "peer-left", peerId: "alice-home" },
      joinedAt(600, "alice-laptop", ALICE_DESIGNATOR),
    ]));
    assertEquals(
      [...claimedPeerByEnd(doc).keys()],
      [],
      "an ambiguous claim resolved to one of the two peers",
    );

    const early = readingAt(doc, 200);
    assertEquals(
      [...early.drawnAsClaim],
      [],
      "the frame drew as a claim an end the layout would not lean",
    );
    const claim = early.at("s-claim::b");
    const home = early.at("alice-home");
    assert(claim !== undefined && home !== undefined);
    assert(
      dist(claim, home) > NEAR_PEER,
      "the layout leaned an end whose claim names two peers",
    );
    assertEquals(
      early.bundles.get("s-real")?.size,
      1,
      "a real session was nudged off its lane by a claim nobody resolved",
    );
  },
);

layoutTest(
  "a claim naming its own session's far peer is neither leaned nor drawn",
  () => {
    // The degenerate segment, read from both sides. The end claims to be
    // Alice and Alice is already sitting at the other end of this very
    // session, so there is no direction to lean in — and a frame that
    // resolved it anyway would key the pair as Alice-to-Alice, which is not a
    // corridor anything runs along.
    const doc = projectFromObservations(docOf([
      joined("alice", ALICE_DESIGNATOR),
      between("s", { peer: "alice", attributedBy: "self-reported" }, {
        designator: ALICE_DESIGNATOR,
      }),
    ]));
    assertEquals([...claimedPeerByEnd(doc).keys()], []);
    const reading = readingAt(doc, 50);
    assertEquals([...reading.drawnAsClaim], []);
    const claim = reading.at("s::b");
    const alice = reading.at("alice");
    assert(claim !== undefined && alice !== undefined);
    assert(
      dist(claim, alice) > BODIES_TOUCH,
      "the end landed on the peer its own session already reaches",
    );
  },
);

layoutTest("naming a peer on the wire makes the end beside it a claim", () => {
  // A peer's durable name is what a claim matches, so writing one turns an
  // ordinary loose end into a claim about that peer — and the placement has
  // to follow in the same edit. Re-seeking alone left the layout answering
  // from the peer's old identity: the end was drawn as a claim, at half a
  // peer's width and with its wire cut short, while still standing where an
  // ordinary body had been solved.
  const engine = new Engine(docOf([
    joined("carol"),
    joined("alice"),
    opened("s", { designator: ALICE_DESIGNATOR }),
  ]));
  const before = findNode(engine.world, "s::b")?.position;
  assert(before !== undefined, "the loose end was not drawn");
  const alice = findNode(engine.world, "alice")?.position;
  assert(alice !== undefined);
  assert(
    dist(before, alice) > NEAR_PEER,
    "the end was already a claim before anything named the peer",
  );

  engine.dispatch({
    kind: "update-peer",
    peerId: "alice",
    patch: { designator: ALICE_DESIGNATOR },
  });

  const claim = findNode(engine.world, "s::b")?.position;
  const named = findNode(engine.world, "alice")?.position;
  const carol = findNode(engine.world, "carol")?.position;
  assert(claim !== undefined && named !== undefined && carol !== undefined);
  assertEquals(
    [...engine.claims],
    [["s::b", "alice"]],
    "the edit did not reach the claim resolution",
  );
  assertAlmostEquals(
    onSegment(claim, carol, named).along,
    CLAIM_LEAN,
    1e-9,
    "the end was named a claim but never leaned toward the peer it names",
  );
});
