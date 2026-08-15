/**
 * Doc-aware temporal resolver — turns the stored `entity.timing`
 * (layer 1, see `time-span.ts`) into the intrinsic (layer 2) and
 * effective (layer 3) ranges every consumer reads.
 *
 * # Reader → layer
 *
 *   Stage rendering, scrubber, hit-test     → effective
 *   Inspector input field                   → stored (entity.timing)
 *   Inspector "stored vs effective" badge   → intrinsic vs effective
 *   Empty-span check (is it visible?)       → effective.duration <= 0
 *   Undo / wire format                      → stored only
 *
 * Hit-test in particular: see `Scrubber.tsx::hitTestEvents`. It calls
 * `peerEffective` / `sessionEffective` / `messageEffective` so the
 * clickable region of a span is exactly what the renderer painted.
 *
 * # Parent chain
 *
 *   peer     → world (unbounded)
 *   session  → peerA.effective ∩ peerB.effective
 *   message  → session.effective
 *
 * Both `intrinsic` and `effective` walk the chain. The chain is the
 * only place a constraint can shrink an entity below its stored
 * intent.
 *
 * # Invariants
 *
 *   - Reads `entity.timing` only. Observations have already been
 *     projected into timing by `projectFromObservations`; callers
 *     that skip projection get an implicit-implicit fallback so we
 *     don't crash, but the result is meaningless.
 *   - Pure over the doc. No mutation, no caching here — memoization
 *     (if needed) lives in the engine, not in this module.
 *   - Effective.duration can be 0 or "empty" (start > end after
 *     clamping). Renderers treat that as "not visible"; do NOT
 *     interpret it as "deleted".
 */

import type {
  EndpointAttachment,
  EndpointAttribution,
  PeerProfile,
  SessionEndpoint,
  SessionSide,
} from "../../schema/topology.ts";
import { endpointAttachment, endpointNodeId, sessionEndpoint, SessionState } from "../../schema/topology.ts";
import type { SessionDefinition, TimelineDocument } from "../timeline.ts";
import { effectiveOf } from "./effective.ts";
import { intrinsicOf } from "./inheritance.ts";
import { keyframeAt, type KeyframeTrack } from "./keyframes.ts";
import {
  PEER_TRAJECTORY,
  type PeerProperty,
  SESSION_TRAJECTORY,
  type SessionProperty,
  type SessionValue,
} from "../trajectory.ts";
import { type EffectiveRange, intersect } from "./range.ts";
import type { TimeSpan } from "./time-span.ts";
import { WORLD_EFFECTIVE, WORLD_INTRINSIC } from "./world.ts";

export type EntityKind = "peers" | "sessions" | "messages";

const FALLBACK_SPAN: TimeSpan = {
  start: { value: 0, explicit: false },
  duration: { value: 0, explicit: false },
};

function peerSpan(doc: TimelineDocument, id: string): TimeSpan {
  return doc.entities?.peers?.[id]?.timing ?? FALLBACK_SPAN;
}

function sessionSpan(doc: TimelineDocument, id: string): TimeSpan {
  return doc.entities?.sessions?.[id]?.timing ?? FALLBACK_SPAN;
}

function messageSpan(doc: TimelineDocument, id: string): TimeSpan {
  return doc.entities?.messages?.[id]?.timing ?? FALLBACK_SPAN;
}

/** Intrinsic range for a peer — parent is world. */
export function peerIntrinsic(
  doc: TimelineDocument,
  id: string,
): EffectiveRange {
  return intrinsicOf(peerSpan(doc, id), WORLD_INTRINSIC);
}

/** Effective range for a peer — clamped into world (which is
 *  unbounded, so this is effectively the intrinsic). */
export function peerEffective(
  doc: TimelineDocument,
  id: string,
): EffectiveRange {
  return effectiveOf(peerIntrinsic(doc, id), WORLD_EFFECTIVE);
}

/** Every peer that has occupied one end of a session, oldest first:
 * the one it opened with, then each one a
 * `session-endpoint-attributed` observation put there.
 *
 * The one answer to "was this peer ever on this end", so a reader asking it
 * cannot accidentally ask the narrower "is it there at genesis" — which is
 * what comparing a peer id against the endpoint itself amounts to, and the
 * compiler does not catch that. */
export function sessionEndpointOccupants(
  def: SessionDefinition,
  side: SessionSide,
): string[] {
  // Genesis value then track, which is the same shape `sessionEndpointAt`
  // reads one moment out of. A loose end has no occupant at all and yields
  // none, which is what lets the span below stop compensating for one.
  const genesis = def[side].peer;
  const out: string[] = genesis === undefined ? [] : [genesis];
  for (const kf of endpointTrack(def, side) ?? []) {
    if (!out.includes(kf.value.peer)) out.push(kf.value.peer);
  }
  return out;
}

/** One end's attachment track, typed as what it carries.
 *
 *  Read off the definition rather than through `SESSION_TRAJECTORY[side]`,
 *  whose value channel is widened to the union every session property can
 *  carry so that generic code can drive them all. It is the same field, and
 *  the readers below need the pair itself. */
function endpointTrack(
  def: SessionDefinition,
  side: SessionSide,
): KeyframeTrack<EndpointAttachment> | undefined {
  return def.keyframes?.[side];
}

/** How long one end of a session was occupied: from the first occupant's
 * arrival to the last one's departure.
 *
 * An end can change occupant while the session runs. Something backs a claim
 * nobody could name and the end attaches; an author states a later attachment
 * naming somebody else. The span covers all of them rather than their
 * intersection, because the end was occupied throughout — the session ran the
 * whole time — and an intersection would end it the moment one occupant's life
 * stopped overlapping the next.
 *
 * A loose end has no occupant, and no occupant is not a zero-length life: the
 * session is running and one of its ends is simply unattributed. It
 * constrains nothing, so it returns the unbounded range and lets the attached
 * end decide.
 *
 * That holds for an end that is loose for a WHILE just as much as for one that
 * is loose forever, and it is the commonest shape a live feed produces: a host
 * accepts a dialer it cannot name, draws the end loose, and a second producer
 * speaks for that end later. Reading the occupancy off the first attachment
 * alone would date the end from the peer that arrived at it, so a session
 * observed from its open would begin at the attachment instead. Every message
 * it carried before then would go with it, because a message's context is its
 * session. The end was there and unoccupied, so nothing bounds it until
 * somebody arrives. */
function sideContext(
  doc: TimelineDocument,
  def: SessionDefinition,
  side: SessionSide,
): EffectiveRange {
  const occupants = sessionEndpointOccupants(def, side);
  const [first, ...rest] = occupants;
  if (first === undefined) return WORLD_EFFECTIVE;
  let span = peerEffective(doc, first);
  for (const peerId of rest) {
    const eff = peerEffective(doc, peerId);
    span = {
      start: Math.min(span.start, eff.start),
      end: Math.max(span.end, eff.end),
    };
  }
  // Born loose: the end was unoccupied from the session's own start until the
  // first attachment, and an unoccupied end bounds nothing on that side.
  if (def[side].peer === undefined) {
    return { start: WORLD_EFFECTIVE.start, end: span.end };
  }
  return span;
}

/** Context for a session: the intersection of the ranges over which
 *  its two ends were occupied. May be empty when they don't overlap. */
export function sessionContext(
  doc: TimelineDocument,
  id: string,
): EffectiveRange {
  const def = doc.entities?.sessions?.[id];
  if (!def) return WORLD_EFFECTIVE;
  return intersect(sideContext(doc, def, "a"), sideContext(doc, def, "b"));
}

export function sessionIntrinsic(
  doc: TimelineDocument,
  id: string,
): EffectiveRange {
  // Inheritance reads parent intrinsic, but for sessions we use the
  // peer-overlap context for both layers — sessions' "intrinsic
  // parent" is the same peer intersection we'd clamp against. The
  // distinction between session.intrinsic and session.effective is
  // carried by the session's own span values, not by two different
  // parent ranges.
  const ctx = sessionContext(doc, id);
  return intrinsicOf(sessionSpan(doc, id), ctx);
}

export function sessionEffective(
  doc: TimelineDocument,
  id: string,
): EffectiveRange {
  return effectiveOf(sessionIntrinsic(doc, id), sessionContext(doc, id));
}

/** Context for a message: its session's effective range. */
export function messageContext(
  doc: TimelineDocument,
  id: string,
): EffectiveRange {
  const def = doc.entities?.messages?.[id];
  if (!def) return WORLD_EFFECTIVE;
  return sessionEffective(doc, def.sessionId);
}

export function messageIntrinsic(
  doc: TimelineDocument,
  id: string,
): EffectiveRange {
  // See sessionIntrinsic comment — same simplification.
  const ctx = messageContext(doc, id);
  return intrinsicOf(messageSpan(doc, id), ctx);
}

export function messageEffective(
  doc: TimelineDocument,
  id: string,
): EffectiveRange {
  return effectiveOf(messageIntrinsic(doc, id), messageContext(doc, id));
}

/** The value one of a session's temporal properties carries at `t`:
 * the latest keyframe at or before `t`, else the value the session
 * was born with. Undefined when the session isn't declared, or when
 * nothing ever stated the property — an end nothing has attributed
 * carries no peer, and that is the answer rather than a gap.
 *
 * The session sibling of `peerValueAt`, and the one resolution behind
 * both named readers below. Which properties exist is
 * `trajectory.ts`'s business, not this module's. */
export function sessionPropertyValueAt(
  doc: TimelineDocument,
  sessionId: string,
  property: SessionProperty,
  t: number,
): SessionValue | undefined {
  const def = doc.entities?.sessions?.[sessionId];
  if (def === undefined) return undefined;
  const spec = SESSION_TRAJECTORY[property];
  return keyframeAt(spec.track(def), t) ?? spec.genesis(def);
}

/** The one string that names what a property carries at `t` — the reader
 * above narrowed through the property's `stated` channel.
 *
 * An end carries a pair, so this answers with the peer alone and a caller
 * that needs what backed the attachment asks `sessionPropertyValueAt` or
 * `sessionEndpointAt`. It is a second name for one resolution rather than a
 * second resolution, so the two cannot answer about different moments. */
export function sessionValueAt(
  doc: TimelineDocument,
  sessionId: string,
  property: SessionProperty,
  t: number,
): string | undefined {
  const value = sessionPropertyValueAt(doc, sessionId, property, t);
  return value === undefined ? undefined : SESSION_TRAJECTORY[property].stated(value);
}

/** Resolved session state at `t`, falling back to the schema default
 * for a session that says nothing. This is what the state IS at `t`:
 * what the world materializer paints and the Inspector reads.
 *
 * Not what a write is judged against: whether stating a state changes
 * the document is a question about the DECLARATION at `t`, which
 * `no-op-guards.ts` asks of the track itself. */
export function sessionStateAt(
  doc: TimelineDocument,
  sessionId: string,
  t: number,
): SessionState {
  const at = sessionValueAt(doc, sessionId, "state", t);
  // The state picker is closed and its write refuses anything else,
  // so a value outside the set can only reach here from a hand-edited
  // document; such a document gets the default rather than a state
  // nothing else in the app can paint.
  return at !== undefined && (SessionState.options as readonly string[])
      .includes(at)
    ? at as SessionState
    : "negotiating";
}

/** One end of a session as it stands at `t`: what it claims, the peer it is
 * attached to, and what backed that attachment.
 *
 * The whole end, resolved — which is the one thing a bare peer id could never
 * be. An end's claim is stated once when the session opens and never restated,
 * so it comes off the genesis endpoint; who is attached and what put them
 * there arrive together, change together, and come off the attachment in
 * effect at `t` (`EndpointAttachment`). A reader that asked for the peer at
 * the playhead and the attribution at genesis got a pair of answers from two
 * different moments, and printed "attached to Bob" beside "nothing proved
 * this" for an attachment a signed handoff had proved.
 *
 * An undeclared session answers with a loose end, because that is what the
 * document says about it: nothing. */
export function sessionEndpointAt(
  doc: TimelineDocument,
  sessionId: string,
  side: SessionSide,
  t: number,
): SessionEndpoint {
  const def = doc.entities?.sessions?.[sessionId];
  if (def === undefined) return sessionEndpoint({});
  const end = def[side];
  const at = keyframeAt(endpointTrack(def, side), t) ?? endpointAttachment(end);
  const designator = end.designator;
  if (at === undefined) return sessionEndpoint({ designator });
  return sessionEndpoint({
    peer: at.peer,
    designator,
    attributedBy: at.attributedBy,
  });
}

/** Where one end of a session sits at `t`, who is there, and what put them
 * there.
 *
 * `node` is what the stage draws the edge to: the peer attached to the
 * end, or the end's own stage id when nothing has attributed it.
 * `peer` is that peer, and its absence IS the "this end is loose"
 * test — the one place either question is answered, so the stage, the
 * inspector, and every reader that walks the graph agree about which
 * ends are loose and where the line goes. `attributedBy` is what backed the
 * attachment in effect at `t`, so a panel reading this reads both halves of
 * one fact from one moment. Spelling it out at a call
 * site takes two facts (`sessionEndpointAt` and `endpointStageId`)
 * and puts the relation between them back in prose. */
export function sessionEndpointPlaceAt(
  doc: TimelineDocument,
  sessionId: string,
  side: SessionSide,
  t: number,
): {
  node: string;
  peer: string | undefined;
  attributedBy: EndpointAttribution | undefined;
} {
  const end = sessionEndpointAt(doc, sessionId, side, t);
  // `endpointNodeId` is the same rule for a caller holding the endpoint
  // itself rather than a document and a moment; resolving the tracks first
  // is the whole of what this adds.
  return {
    node: endpointNodeId(sessionId, side, end),
    peer: end.peer,
    attributedBy: end.attributedBy,
  };
}

/** The value one of a peer's temporal properties carries at `t`:
 * the latest keyframe at or before `t`, else what the peer arrived
 * with. Undefined when the peer never carried one. Which properties
 * exist is `trajectory.ts`'s business, not this module's. */
export function peerValueAt(
  doc: TimelineDocument,
  peerId: string,
  property: PeerProperty,
  t: number,
): string | undefined {
  const def = doc.entities?.peers?.[peerId];
  if (def === undefined) return undefined;
  const spec = PEER_TRAJECTORY[property];
  return keyframeAt(spec.track(def), t) ?? spec.genesis(def);
}

/** What one of a peer's temporal properties carries when the peer ARRIVES,
 * always — before any moment restates it.
 *
 * `peerPropertyAt` is the reader for what a peer is at a moment; this is the
 * reader for what it was born with, which is a different question and has a
 * different writer. The Inspector's Details pickers edit the arrival value,
 * so they read it here rather than reading the playhead's value and writing
 * this one. Falls back the same way, through the property's own declared
 * fallback, so neither reader spells a default the table already owns. */
export function peerGenesisValue(
  doc: TimelineDocument,
  peerId: string,
  property: PeerProperty,
): string {
  const def = doc.entities?.peers?.[peerId];
  const spec = PEER_TRAJECTORY[property];
  return (def && spec.genesis(def)) ?? spec.fallback(peerId);
}

/** What one of a peer's temporal properties carries at `t`, always.
 *
 * `peerValueAt` answers what the document *says*, which can be
 * nothing. This answers what the peer *is*, by falling back to the
 * property's declared value for saying nothing — so a caller holding
 * a `PeerProperty` it cannot name gets a real value back rather than
 * having to invent one. The three named readers below are this
 * function with a return type; the trajectory insert control calls
 * it generically. */
export function peerPropertyAt(
  doc: TimelineDocument,
  peerId: string,
  property: PeerProperty,
  t: number,
): string {
  return peerValueAt(doc, peerId, property, t) ??
    PEER_TRAJECTORY[property].fallback(peerId);
}

/** The name a peer answers to at `t`, falling back to its id so
 * every surface has something to show. The named reader for the
 * `label` property: the stage, the Inspector, and the timeline lane
 * all call this, so they agree about who is who at a given moment. */
export function peerLabelAt(
  doc: TimelineDocument,
  peerId: string,
  t: number,
): string {
  return peerPropertyAt(doc, peerId, "label", t);
}

/** The implementation flavor a peer is known by at `t`, falling
 * back to the one it joined under. The named reader for the
 * `profile` property, beside `peerLabelAt`: the stage colors peers
 * with it, and the Inspector names it. */
export function peerProfileAt(
  doc: TimelineDocument,
  peerId: string,
  t: number,
): PeerProfile {
  return peerPropertyAt(doc, peerId, "profile", t);
}

/** Effective t for a single-moment observation parented to an
 * entity: a session's state-change diamond, a peer's rename. Same
 * saturating-clamp semantics the span resolvers use: a stored t
 * outside the parent's effective range collapses to the nearest
 * boundary so the glyph remains visible and clickable inside its
 * pill. When the id doesn't resolve to a declared entity (orphan
 * glyph), the raw t passes through. */
export function momentEffective(
  doc: TimelineDocument,
  kind: EntityKind,
  id: string,
  t: number,
): number {
  if (doc.entities?.[kind]?.[id] === undefined) return t;
  const eff = effectiveOfEntity(doc, kind, id);
  if (t < eff.start) return eff.start;
  if (Number.isFinite(eff.end) && t > eff.end) return eff.end;
  return t;
}

/** Dispatch helper — kind-keyed effective range. */
export function effectiveOfEntity(
  doc: TimelineDocument,
  kind: EntityKind,
  id: string,
): EffectiveRange {
  if (kind === "peers") return peerEffective(doc, id);
  if (kind === "sessions") return sessionEffective(doc, id);
  return messageEffective(doc, id);
}

/** Dispatch helper — kind-keyed intrinsic range. */
export function intrinsicOfEntity(
  doc: TimelineDocument,
  kind: EntityKind,
  id: string,
): EffectiveRange {
  if (kind === "peers") return peerIntrinsic(doc, id);
  if (kind === "sessions") return sessionIntrinsic(doc, id);
  return messageIntrinsic(doc, id);
}

/** Names the parent that's clamping a given side of an entity's
 * intrinsic into its effective range. Returns null when the
 * intrinsic value passes through unchanged on that side.
 *
 * For peers, parent is world (unbounded) — never clamps.
 * For sessions, parent is the peer-overlap context — the clamping
 *   peer is whichever endpoint forces the tighter bound.
 * For messages, parent is the session's effective range. */
export function clampReasonFor(
  doc: TimelineDocument,
  kind: EntityKind,
  id: string,
  side: "start" | "end",
): string | null {
  if (kind === "peers") return null;
  const intrinsic = intrinsicOfEntity(doc, kind, id);
  const effective = effectiveOfEntity(doc, kind, id);
  if (side === "start" && intrinsic.start >= effective.start) return null;
  if (side === "end" && intrinsic.end <= effective.end) return null;

  if (kind === "sessions") {
    const def = doc.entities?.sessions?.[id];
    if (!def) return null;
    // Whichever END forces the tighter bound, named by the peer that
    // sets it. An end that changed hands is held by the occupant
    // reaching furthest in that direction, because that is the one
    // the side's own range came from.
    // A loose end has no occupant, so it binds nothing and yields nothing
    // to name here; the attached end is what set the range.
    const bound = (
      s: SessionSide,
    ): { peerId: string; at: number } | undefined => {
      let held: { peerId: string; at: number } | undefined;
      for (const peerId of sessionEndpointOccupants(def, s)) {
        const eff = peerEffective(doc, peerId);
        const at = side === "start" ? eff.start : eff.end;
        const better = held === undefined ||
          (side === "start" ? at < held.at : at > held.at);
        if (better) held = { peerId, at };
      }
      return held;
    };
    const a = bound("a");
    const b = bound("b");
    if (a === undefined && b === undefined) return null;
    if (a === undefined) return `peer ${b!.peerId}`;
    if (b === undefined) return `peer ${a.peerId}`;
    const tighter = side === "start" ? (a.at >= b.at ? a.peerId : b.peerId) : (a.at <= b.at ? a.peerId : b.peerId);
    return `peer ${tighter}`;
  }

  // messages
  const def = doc.entities?.messages?.[id];
  if (!def) return null;
  return `session ${def.sessionId}`;
}
