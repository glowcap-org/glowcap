/**
 * Who stands on the stage at a moment.
 *
 * An era is a statement about `t`, not about everything that had happened by
 * then. `layout-eras.ts` owns the era list; `KeyframeLayoutSystem` applies it
 * at `t`. This module owns the moments the walk stops at, and the
 * nodes and session links standing at each one. The world materializer asks a
 * narrower question of the same document (effective ranges only). Membership
 * here also asks whether the walk has reached an entity, so an unprojected
 * document does not show a session at t=0 whose observation arrives later.
 */

import { endpointNodeId } from "../../schema/session-end.ts";
import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import { observationsOf } from "../temporal/recording-access.ts";
import { containsTime } from "../temporal/range.ts";
import { peerEffective, sessionEffective } from "../temporal/doc-resolver.ts";
import { sessionEnds } from "../claims.ts";

/** One thing arriving on stage or leaving it, at the moment it happens. */
export type TopologyChange =
  | { t: number; kind: "peer-in"; peerId: string }
  | { t: number; kind: "peer-out"; peerId: string }
  | { t: number; kind: "session-in"; sessionId: string; a: string; b: string }
  | { t: number; kind: "session-out"; sessionId: string };

export type StandingSession = { id: string; a: string; b: string };

/**
 * Every moment the walk stops at, in time order.
 *
 * An entity arrives and departs once, and what states those two moments
 * depends on which kind of entity it is. An entity an observation ANNOUNCES is
 * stated by its observations: a join and the peer-left or peer-unobserved that
 * ends its row, an open and the close or session-unobserved that ends its own.
 * An entity only the DOCUMENT declares — one authored in Build, which simply
 * is — has no observations at all, so its declared timing states both. Without
 * that second half a Build-authored entity reached no era, so its position
 * fell back to the origin and every unattributed end piled on the same spot;
 * with it, an entity timed to a window arrives when the window opens and
 * leaves when it closes, exactly as an observed one does.
 *
 * One stream, so one moment cannot be reached twice. When the seed of the
 * declared entities was a keyframe of its own, a document that declared
 * anything and also observed something at t=0 got two keyframes at t=0, and
 * the stage then animated between them at a moment nothing had changed.
 */
export function topologyChanges(doc: TimelineDocument): TopologyChange[] {
  const changes: TopologyChange[] = [];
  const announcedPeers = new Set<string>();
  const announcedSessions = new Set<string>();
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    switch (ev.kind) {
      case "peer-joined":
        announcedPeers.add(ev.peerId);
        changes.push({ t: ev.t, kind: "peer-in", peerId: ev.peerId });
        break;
      case "peer-left":
      case "peer-unobserved":
        changes.push({ t: ev.t, kind: "peer-out", peerId: ev.peerId });
        break;
      case "session-opened":
        announcedSessions.add(ev.sessionId);
        changes.push({
          t: ev.t,
          kind: "session-in",
          sessionId: ev.sessionId,
          a: endpointNodeId(ev.sessionId, "a", ev.a),
          b: endpointNodeId(ev.sessionId, "b", ev.b),
        });
        break;
      case "session-closed":
      case "session-unobserved":
        changes.push({ t: ev.t, kind: "session-out", sessionId: ev.sessionId });
        break;
    }
  }
  for (const peerId of Object.keys(doc.entities?.peers ?? {})) {
    if (announcedPeers.has(peerId)) continue;
    const range = peerEffective(doc, peerId);
    changes.push({ t: range.start, kind: "peer-in", peerId });
    if (Number.isFinite(range.end)) {
      changes.push({ t: range.end, kind: "peer-out", peerId });
    }
  }
  for (const [sessionId, ends] of sessionEnds(doc)) {
    if (announcedSessions.has(sessionId)) continue;
    const range = sessionEffective(doc, sessionId);
    changes.push({
      t: range.start,
      kind: "session-in",
      sessionId,
      a: ends.a,
      b: ends.b,
    });
    if (Number.isFinite(range.end)) {
      changes.push({ t: range.end, kind: "session-out", sessionId });
    }
  }
  // By time, stably: the observations are already in order and the declared
  // entities are read in key order, so a document sorts one way every run.
  changes.sort((x, y) => x.t - y.t);
  return changes;
}

/**
 * Which of the sessions the walk has reached are on stage at `t`.
 *
 * Asked of the document's effective ranges, which is the same question
 * `materializeWorldAt` asks of every session before drawing it. It has to be
 * the same question: a session is one lane of its pair's bundle, so a session
 * the world draws and the layout does not means the two count that bundle
 * differently — and a claim placed on a lane of a two-lane bundle sits off the
 * arc drawn along a one-lane one. The observations say when the topology
 * changed; the ranges say what is standing there, and only one of them can be
 * the authority on the second question.
 */
function sessionsOnStageAt(
  doc: TimelineDocument,
  sessions: ReadonlyMap<string, { a: string; b: string }>,
  t: number,
): StandingSession[] {
  const out: StandingSession[] = [];
  for (const [id, ends] of sessions) {
    if (!containsTime(sessionEffective(doc, id), t)) continue;
    out.push({ id, a: ends.a, b: ends.b });
  }
  // In id order, for the same reason the node ids are sorted before they are
  // seeded: d3 accumulates link forces in array order, so a list in the order
  // the sessions happened to be stated would settle one document into two
  // pictures depending on which author added which session first.
  out.sort((x, y) => (x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
  return out;
}

/**
 * The session links standing at `t`.
 *
 * Two conditions, and both were in the old fold: the walk has to have reached
 * the session, and the session's own range has to hold `t`. Reached is what the
 * accumulating map used to carry, and it is not the same question as the range,
 * because a document whose observations have not been projected resolves a
 * session's start to an implicit zero — so a session opened at t=100 would
 * otherwise stand at t=0 as well, and the era before it would already show its
 * link.
 *
 * Derived from the moments rather than folded, so it stays a statement about
 * `t`: a session is reached once its own arrival moment is at or before `t`.
 */
export function linksStandingAt(
  doc: TimelineDocument,
  changes: readonly TopologyChange[],
  allSessions: ReadonlyMap<string, { a: string; b: string }>,
  t: number,
): StandingSession[] {
  const reached = new Map<string, { a: string; b: string }>();
  for (const change of changes) {
    if (change.t > t) break;
    if (change.kind !== "session-in") continue;
    const ends = allSessions.get(change.sessionId);
    if (ends !== undefined) reached.set(change.sessionId, ends);
  }
  return sessionsOnStageAt(doc, reached, t);
}

/**
 * The nodes standing at `t`, in the sorted order `runForce` wants.
 *
 * Asked of the document's effective ranges, for the same reason
 * `sessionsOnStageAt` asks them of the links: an era has to describe the moment
 * it is stamped at rather than everything that had happened by then.
 *
 * Not quite the same question, though, and the difference is a trade rather than
 * an oversight. This asks reached AND standing; the world asks only standing
 * (`world-materializer.ts`). So a peer whose authored timing starts before the
 * observation that announces it is on stage, with no entry in the era covering
 * that gap, and `update` leaves it wherever it was. Reached is what makes an
 * unprojected document behave, and the fold this replaced carried the same gap.
 *
 * It used to be a set folded forward across the walk, and a session's departure
 * did not remove the ends it had added — `peer-out` only reaches an id a
 * `peer-joined` or a declared peer named, and a loose end's stage id is neither.
 * So a session that opened and closed left its end in the node set of every
 * later era, as a free body with charge and a footprint, seeded at the origin
 * with nothing standing there. A live room that opens a session every few
 * seconds accumulated one such body per session for as long as anyone watched,
 * piling them at the center of the picture and pushing every real peer outward
 * a little further each time. Deriving the set from the moment is what makes an
 * era a statement about that moment, and it is also what lets two eras be
 * compared at all: while the set grew forever, no two of them were ever equal.
 */
export function nodesStandingAt(
  doc: TimelineDocument,
  changes: readonly TopologyChange[],
  links: ReadonlyArray<StandingSession>,
  t: number,
): string[] {
  const nodes = new Set<string>();
  for (const change of changes) {
    // Reached, then standing: the same two conditions the links answer to, and
    // for the same reason.
    if (change.t > t) break;
    if (change.kind !== "peer-in") continue;
    if (containsTime(peerEffective(doc, change.peerId), t)) {
      nodes.add(change.peerId);
    }
  }
  // An end of a session standing here stands here too, whether it names a peer
  // (in which case this is that peer, already counted) or nothing at all.
  for (const link of links) {
    nodes.add(link.a);
    nodes.add(link.b);
  }
  return [...nodes].sort();
}
