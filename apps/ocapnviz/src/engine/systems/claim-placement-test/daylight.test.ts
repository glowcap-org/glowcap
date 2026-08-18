/**
 * Why the lean is two thirds: daylight on every session edge the
 * shipped recordings settle, measured between bodies and between
 * focus rings.
 */

import { assert, assertAlmostEquals } from "@std/assert";
import { CLAIM_LEAN } from "../claim-placement.ts";
import { DEFAULT_LAYOUT_CONFIG, KeyframeLayoutSystem } from "../keyframe-layout-system.ts";
import { claimedPeerByEnd } from "../../claims.ts";
import { haloRadius, LOOSE_END_CLAIMING, NODE_RADIUS } from "../../../render/draw-helpers.ts";
import { endpointStageId, SESSION_SIDES, type SessionEndpoint, type SessionSide } from "../../../schema/session-end.ts";
import { scenarios } from "../../../fixtures/index.ts";
import { BODIES_TOUCH, CLAIM_DAYLIGHT, dist, layoutTest, NEAR_PEER, RING_DAYLIGHT } from "./harness.ts";

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
 *  solve, which is the case `lean.test.ts` covers. */
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
    ): string | undefined => end.peer ?? claimed.get(endpointStageId(sessionId, side));
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
        `a claim on a ${edge.length.toFixed(0)}-unit edge landed far enough out to read as a node of its own`,
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
      } of the peer's on the shortest edge the recordings settle, which is ${shortest.toFixed(0)} long`,
    );
    assert(
      ringGapOn(shortest, 3 / 4) < RING_DAYLIGHT,
      `three quarters leaves ${
        ringGapOn(shortest, 3 / 4).toFixed(0)
      } between the rings on that same edge, which already clears a claim's own body, so the fraction is arbitrary`,
    );
  },
);
