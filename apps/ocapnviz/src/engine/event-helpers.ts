/**
 * Event-side helpers for the engine. Pure functions over
 * `TimelineEvent`; no dependencies on the engine or the world.
 *
 * Reference-walking used to live here too (`eventReferencesPeer`
 * etc.) — that knowledge has moved to the schema-driven primitives
 * in `engine/schema/`. For ref walks, use `findEventRefs` from
 * `engine/schema/walk.ts` instead.
 */

import type { TimelineDocument, TimelineEvent } from "./timeline.ts";
import {
  type MomentLane,
  type PeerProperty,
  type PeerUpdate,
  peerUpdateStates,
  SESSION_TRAJECTORY,
  sessionMomentOf,
} from "./trajectory.ts";
import { observationsOf } from "./temporal/recording-access.ts";
import { type EngineError, validationError } from "./errors.ts";
import { endpointStageId, SESSION_SIDES } from "../schema/topology.ts";

/** Kinds whose application changes the topology graph (peers + sessions). */
export function isTopologyChange(kind: TimelineEvent["kind"]): boolean {
  return kind === "peer-joined" || kind === "peer-left" ||
    kind === "session-opened" || kind === "session-closed";
}

/** Generic order-by-rowOrder. Listed ids come first in the given
 * order; unlisted items keep their original (insertion) order
 * behind. Unknown ids in the override (e.g. a saved entry whose
 * entity no longer exists) are silently dropped. Used by the
 * Engine's `orderedPeers/Sessions/Messages` so ECS consumers
 * don't have to remember to sort; also reused by `applyRowOrder`
 * for the id-only call sites in the Timeline. */
export function orderByRowOrder<T>(
  items: readonly T[],
  idOf: (item: T) => string,
  override: readonly string[] | undefined,
): T[] {
  if (!override || override.length === 0) return [...items];
  const byId = new Map<string, T>();
  for (const item of items) byId.set(idOf(item), item);
  const result: T[] = [];
  const seen = new Set<string>();
  for (const id of override) {
    if (seen.has(id)) continue;
    const item = byId.get(id);
    if (item !== undefined) {
      result.push(item);
      seen.add(id);
    }
  }
  for (const item of items) {
    if (!seen.has(idOf(item))) result.push(item);
  }
  return result;
}

/** Id-list specialization of `orderByRowOrder` — same contract,
 * shorter call site for the common case where the input is
 * already a list of ids (Timeline lane bundles, etc.). */
export function applyRowOrder(
  insertionOrdered: readonly string[],
  order: readonly string[] | undefined,
): string[] {
  return orderByRowOrder(insertionOrdered, (id) => id, order);
}

/** Find a `message-sent` event by id, scanning the doc. The world
 * only carries in-flight messages; once delivered they're gone, but
 * the doc still has them and that's what `update-message` wants. */
export function findMessageInDoc(
  doc: TimelineDocument,
  messageId: string,
): Extract<TimelineEvent, { kind: "message-sent" }> | null {
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    if (ev.kind === "message-sent" && ev.messageId === messageId) return ev;
  }
  return null;
}

/** Entity-keyed observation lookups used by the Inspector's time
 * fields and by the Scrubber's hit-test. Each entity has a canonical
 * "birth" observation whose `t` is what the user means by the
 * entity's recorded start time. Reads the recording layer via
 * `observationsOf`. */
export function findPeerJoinedEvent(
  doc: TimelineDocument,
  peerId: string,
): Extract<TimelineEvent, { kind: "peer-joined" }> | null {
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    if (ev.kind === "peer-joined" && ev.peerId === peerId) return ev;
  }
  return null;
}

/** A peer's authored position — the pin the force layouts hold.
 * Definition first (source of truth), `peer-joined` event mirror
 * second; null means the layout owns the peer's placement. The one
 * lookup the no-op guards and the Inspector share. */
export function authoredPeerPosition(
  doc: TimelineDocument,
  peerId: string,
): { x: number; y: number } | null {
  const def = doc.entities?.peers?.[peerId];
  if (def?.position) return def.position;
  return findPeerJoinedEvent(doc, peerId)?.position ?? null;
}

/** Every pin the document holds, keyed by the stage node it places.
 *
 * The two kinds of node pin in two places, because an end nothing has
 * attributed has no entity of its own: a peer's pin is
 * `authoredPeerPosition` above, and an end's pin lives on the session it is
 * an end of, under `endpointPosition`. A caller asking "what is pinned" has
 * to ask both, so it is asked once, here.
 *
 * Keys are stage node ids, so `nodeKindOf` tells a caller which unpin intent
 * a key wants. `KeyframeLayoutSystem` reads this too: authored mode takes it
 * as the layout itself, and the force modes take it as the set of nodes they
 * hold fixed, so what an author placed and what the solver refuses to move are
 * one answer. */
export function authoredPins(
  doc: TimelineDocument,
): Map<string, { x: number; y: number }> {
  const pins = new Map<string, { x: number; y: number }>();
  for (const [peerId, def] of Object.entries(doc.entities?.peers ?? {})) {
    if (def.position) pins.set(peerId, def.position);
  }
  for (const [sessionId, def] of Object.entries(doc.entities?.sessions ?? {})) {
    for (const side of SESSION_SIDES) {
      const at = def.endpointPosition?.[side];
      if (at) pins.set(endpointStageId(sessionId, side), at);
    }
  }
  // A peer whose definition carries no pin may still have been placed by the
  // observation that recorded it joining; `authoredPeerPosition` reads the
  // definition first for the same reason, and one unpin clears both.
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    if (ev.kind !== "peer-joined" || pins.has(ev.peerId)) continue;
    if (ev.position) pins.set(ev.peerId, ev.position);
  }
  return pins;
}

export function findPeerLeftEvent(
  doc: TimelineDocument,
  peerId: string,
): Extract<TimelineEvent, { kind: "peer-left" }> | null {
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    if (ev.kind === "peer-left" && ev.peerId === peerId) return ev;
  }
  return null;
}

/** How a peer's row ended, and when. Null while it is still open.
 *
 * Two kinds, and they say different things: the peer DEPARTED
 * (`left`, a fact about the network), or the viewer stopped being
 * able to see it (`unobserved`, the viewer losing it — the network
 * said nothing).
 *
 * A row has ONE ending, so every reader that needs "when did this
 * stop" asks here rather than remembering how many kinds there are.
 * The earliest wins, which is the rule the projection derives the
 * span from — that is the point of one answer. */
export function peerEnding(
  doc: TimelineDocument,
  peerId: string,
): { t: number; how: "left" | "unobserved" } | null {
  const found: { t: number; how: "left" | "unobserved" }[] = [];
  const left = findPeerLeftEvent(doc, peerId);
  if (left !== null) found.push({ t: left.t, how: "left" });
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    if (ev.kind === "peer-unobserved" && ev.peerId === peerId) {
      found.push({ t: ev.t, how: "unobserved" });
      break;
    }
  }
  let first: { t: number; how: "left" | "unobserved" } | null = null;
  for (const row of found) if (first === null || row.t < first.t) first = row;
  return first;
}

/** The moment an observation is, or null when it is not one: which
 * lane it paints on and which entity it belongs to. A session's
 * state change belongs to its session, a peer's update to its peer,
 * and an update that states nothing changes nothing — so it is not a
 * moment at all.
 *
 * One function, read by everything with an opinion about diamonds:
 * the lane painter, the click hit-test, the marquee, the drag's
 * clamp, and the Inspector's trajectory rows. They cannot disagree about
 * what a diamond is or whose it is, because one place says. */
export function momentOf(
  ev: TimelineEvent,
): { lane: MomentLane; owner: string } | null {
  // Which session observations are moments is `trajectory.ts`'s
  // business: an end attaching is a moment for the same reason a state
  // change is, and a fourth session property would be one too without
  // this function learning its name.
  const session = sessionMomentOf(ev);
  if (session !== null) {
    return { lane: "sessions", owner: session.sessionId };
  }
  if (ev.kind === "peer-updated") {
    // A peer update that states nothing changes nothing, so it is
    // not a moment. `trajectory.ts` owns what "states something"
    // means, property by property.
    return peerUpdateStates(ev).length > 0
      ? { lane: "peers", owner: ev.peerId }
      : null;
  }
  return null;
}

/** Every update observation on a peer's trajectory, in time order —
 * the moments it restated something about itself, which the
 * projection turns into its keyframe tracks. Reads the observations
 * rather than those tracks because the Inspector addresses each
 * moment by the event it came from. Updates that state nothing are
 * left out; `trajectory.ts` decides what counts. */
export function findPeerUpdateEvents(
  doc: TimelineDocument,
  peerId: string,
): PeerUpdate[] {
  const out: PeerUpdate[] = [];
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    const moment = momentOf(ev);
    if (moment?.lane !== "peers" || moment.owner !== peerId) continue;
    // Narrowing: `momentOf` answers whose moment this is without
    // narrowing the observation, and the rows below read the update's
    // own fields.
    if (ev.kind !== "peer-updated") continue;
    out.push(ev);
  }
  return out.sort((a, b) => a.t - b.t);
}

/** One row per property a peer stated, in the order the Inspector
 * and the timeline list them: by moment, then by the property order
 * `trajectory.ts` declares. One observation can state several
 * properties at one instant, and each gets its own row — a row is
 * "this property took this value here", which is what the reader is
 * looking at. */
export function peerTrajectoryRows(
  doc: TimelineDocument,
  peerId: string,
): { ev: PeerUpdate; property: PeerProperty; value: string }[] {
  const out: { ev: PeerUpdate; property: PeerProperty; value: string }[] = [];
  for (const ev of findPeerUpdateEvents(doc, peerId)) {
    for (const stated of peerUpdateStates(ev)) {
      out.push({ ev, property: stated.property, value: stated.value });
    }
  }
  return out;
}

export function findSessionOpenedEvent(
  doc: TimelineDocument,
  sessionId: string,
): Extract<TimelineEvent, { kind: "session-opened" }> | null {
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    if (ev.kind === "session-opened" && ev.sessionId === sessionId) return ev;
  }
  return null;
}

export function findSessionClosedEvent(
  doc: TimelineDocument,
  sessionId: string,
): Extract<TimelineEvent, { kind: "session-closed" }> | null {
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    if (ev.kind === "session-closed" && ev.sessionId === sessionId) return ev;
  }
  return null;
}

/** Where each moving event will land, by event id. One gesture
 * moves a whole entity — a peer with its updates and its departure,
 * a session with its state changes and its close — so an ordering
 * check reads a partner's time through this map. */
export type PlannedTimes = ReadonlyMap<string, number>;

/** The time an event has once the plan lands: its planned time when
 *  the plan moves it, otherwise where it sits now. */
function plannedTimeOf(
  ev: TimelineEvent,
  planned: PlannedTimes | undefined,
): number {
  return planned?.get(ev.id) ?? ev.t;
}

/** Validate that moving `ev` to `newT` doesn't violate the doc's
 * pairing / lifecycle ordering. Used by `move-event`. Returns `null`
 * when the move is OK; an `EngineError` the caller can surface
 * verbatim through `ctx.emitError` when the move would invert a
 * required ordering.
 *
 * `planned` carries the rest of the same gesture. Judging a slid
 * event against where its partner sits *now* would refuse a whole
 * peer or session dragged earlier, because the partner has not been
 * written yet when the check runs. */
export function checkMoveOrdering(
  ev: TimelineEvent,
  newT: number,
  events: readonly TimelineEvent[],
  planned?: PlannedTimes,
): EngineError | null {
  // peer-left must stay after its peer-joined.
  if (ev.kind === "peer-left") {
    const joined = events.find(
      (e) => e.kind === "peer-joined" && e.peerId === ev.peerId,
    );
    if (joined) {
      const joinedT = plannedTimeOf(joined, planned);
      if (newT < joinedT) {
        return validationError(
          `Peer-left (${newT}) cannot land before the peer joins (${joinedT}).`,
          "Drag the leave marker after the join, or move the join earlier.",
        );
      }
    }
  }
  // An update must stay inside the peer's life — a peer cannot take
  // a value before it arrives.
  if (ev.kind === "peer-updated") {
    const joined = events.find(
      (e) => e.kind === "peer-joined" && e.peerId === ev.peerId,
    );
    if (joined) {
      const joinedT = plannedTimeOf(joined, planned);
      if (newT < joinedT) {
        return validationError(
          `Update (${newT}) cannot land before the peer joins (${joinedT}).`,
          "Drag the change after the join, or move the join earlier.",
        );
      }
    }
  }
  // Every moment on a session's trajectory, and its close, must stay
  // after its session-opened — a session cannot change state or gain
  // an end before it exists. Which observations are moments comes from
  // `trajectory.ts`, so a fourth session property is covered here the
  // day it is declared.
  const sessionMoment = sessionMomentOf(ev);
  const boundedBySession = sessionMoment?.sessionId ??
    (ev.kind === "session-closed" ? ev.sessionId : undefined);
  if (boundedBySession !== undefined) {
    const sessionId = boundedBySession;
    const opened = events.find(
      (e) => e.kind === "session-opened" && e.sessionId === sessionId,
    );
    if (opened) {
      const openedT = plannedTimeOf(opened, planned);
      if (newT < openedT) {
        const what = sessionMoment === null
          ? "The close"
          : `The ${SESSION_TRAJECTORY[sessionMoment.property].noun} change`;
        return validationError(
          `${what} (${newT}) cannot land before the session opens (${openedT}).`,
          "Drag the marker after session-open, or move the open earlier.",
        );
      }
    }
  }
  // message-sent must stay after its session-opened.
  if (ev.kind === "message-sent") {
    const opened = events.find(
      (e) => e.kind === "session-opened" && e.sessionId === ev.sessionId,
    );
    if (opened) {
      const openedT = plannedTimeOf(opened, planned);
      if (newT < openedT) {
        return validationError(
          `Message-sent (${newT}) cannot land before the session opens (${openedT}).`,
          "Drag the send marker after session-open, or move the open earlier.",
        );
      }
    }
  }
  return null;
}

/** Companion to `checkMoveOrdering`: when a `message-sent`
 * moves, its paired `message-delivered` slides too. Returns `null`
 * if the delivered side is OK at `newDeliveredT`, or an `EngineError`
 * the caller emits otherwise. */
export function checkDeliveredOrdering(
  events: readonly TimelineEvent[],
  deliveredEventId: string,
  newDeliveredT: number,
  planned?: PlannedTimes,
): EngineError | null {
  const delivered = events.find((e) => e.id === deliveredEventId);
  if (!delivered || delivered.kind !== "message-delivered") return null;
  // Find the matching send + the session-closed (if any) — a
  // delivered must precede a session-closed for its session.
  const sent = events.find(
    (e) => e.kind === "message-sent" && e.messageId === delivered.messageId,
  );
  if (sent && sent.kind === "message-sent") {
    const closed = events.find(
      (e) => e.kind === "session-closed" && e.sessionId === sent.sessionId,
    );
    if (closed) {
      const closedT = plannedTimeOf(closed, planned);
      if (newDeliveredT > closedT) {
        return validationError(
          `Message arrives (${newDeliveredT}) after the session closes (${closedT}).`,
          "Move arrival before session-close, or extend the session.",
        );
      }
    }
  }
  return null;
}
