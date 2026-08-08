/**
 * Project observations into the behavior layer.
 *
 * The recording layer holds observations from a network simulator
 * or other live capture. This module is the one-way **projection**
 * that derives each entity's span (and, in the future, keyframes)
 * from those observations.
 *
 * Used by:
 *   - Live ingest:    every engine tick re-runs the projection, so
 *                     a late-arriving closure observation
 *                     (`peer-left`, `session-closed`) re-derives
 *                     the entity's span the tick it lands.
 *   - Replay-from-    operator gesture: blow away all behavior,
 *     recording      re-project everything from the observation
 *                     stream.
 *   - Doc load:       backfill span on any entity that doesn't yet
 *                     carry one (e.g. fixtures whose entities are
 *                     declared without a timing block).
 *
 * Projection rules (see `docs/data-model.md` and `temporal-model.md`):
 *   - peer.span.start    = peer-joined observation ? explicit(t) : implicit(0)
 *   - peer.span.duration = the observation that ended the peer's row
 *                          (`peer-left`, or the `peer-unobserved` that
 *                          says the viewer lost sight of it)
 *                          ? explicit(end-start) : implicit(0)
 *   - same shape for sessions (session-opened / session-closed)
 *   - message.span.start    = message-sent observation ? explicit(t) : implicit(0)
 *   - message.span.duration = explicit(flightMs ?? 500)
 *                              — messages always have explicit duration
 *
 * # Timing provenance
 *
 * Every span this module writes is marked `derived` (see
 * `TimeSpan.derived`). A derived span is re-derived on every run, so
 * observations that arrive after the entity was first projected — a
 * live feed's closes always do — still land; the result only replaces
 * the stored span when the derivation actually changed, so a quiet
 * run returns the same doc object. An **authored** span (no marker —
 * every authoring op strips it) is never touched: the user's intent
 * outranks the observation stream. Re-running over an unchanged
 * observation set produces an identical doc.
 *
 * Keyframe tracks do not carry the marker yet, so they differ in
 * when they re-derive, and which side of that line a track falls on
 * follows one question: does a live producer emit the observation
 * behind it? A session's state track is derived only while
 * `def.keyframes.state` is unset, then kept, because authoring
 * writes that track directly and no live producer emits
 * `session-state-changed`. A peer's label track and a session's two
 * endpoint tracks re-derive on every run, because `peer-updated` and
 * `session-endpoint-attributed` ARE live arrivals and a track kept
 * after its first derivation would freeze the peer's name at
 * whatever it was called on the tick it first arrived — or leave a
 * session's end loose after something attributed it. Renaming a
 * peer in Build rewrites the observations (`authoring/peer.ts`), so
 * that re-derivation preserves the authored name. When either track
 * gains authored keyframes of its own, both need the provenance
 * treatment spans have.
 */

import type {
  MessageDefinition,
  PeerDefinition,
  SessionDefinition,
  TimelineDocument,
  TimelineEvent,
} from "../timeline.ts";
import { explicitBound, implicitBound } from "./bound.ts";
import type { Keyframe, KeyframeTrack } from "./keyframes.ts";
import { observationsOf } from "./recording-access.ts";
import { isDerived, markDerived, type TimeSpan } from "./time-span.ts";
import type { EndpointAttachment } from "../../schema/topology.ts";
import { SESSION_SIDES, type SessionSide } from "../../schema/topology.ts";
import {
  PEER_PROPERTIES,
  PEER_TRAJECTORY,
  type PeerProperty,
  peerUpdateStates,
  SESSION_TRAJECTORY,
} from "../trajectory.ts";

const DEFAULT_FLIGHT_MS = 500;

type PeerJoined = Extract<TimelineEvent, { kind: "peer-joined" }>;
type PeerLeft = Extract<TimelineEvent, { kind: "peer-left" }>;
type PeerUnobserved = Extract<TimelineEvent, { kind: "peer-unobserved" }>;
type SessionOpened = Extract<TimelineEvent, { kind: "session-opened" }>;
type SessionClosed = Extract<TimelineEvent, { kind: "session-closed" }>;
type SessionUnobserved = Extract<
  TimelineEvent,
  { kind: "session-unobserved" }
>;
type SessionStateChanged = Extract<
  TimelineEvent,
  { kind: "session-state-changed" }
>;
type MessageSent = Extract<TimelineEvent, { kind: "message-sent" }>;

/** The observations that bound one row's life. Each entity has one
 *  start and one ending, and the ending has more than one kind —
 *  named here once so the timing rule below can take "the earliest
 *  of the endings" without knowing what they mean. */
type PeerRow = {
  joined?: PeerJoined;
  left?: PeerLeft;
  unobserved?: PeerUnobserved;
};
type SessionRow = {
  opened?: SessionOpened;
  closed?: SessionClosed;
  unobserved?: SessionUnobserved;
};

/** The first ending to arrive, or undefined while the row is open.
 *  A row has one life, so the earliest ending is the one that ends
 *  it however many kinds were recorded. */
function firstEnding(
  ...endings: ({ t: number } | undefined)[]
): { t: number } | undefined {
  let first: { t: number } | undefined;
  for (const ending of endings) {
    if (ending === undefined) continue;
    if (first === undefined || ending.t < first.t) first = ending;
  }
  return first;
}

/** First-occurrence observation rows per entity id, built in ONE
 *  pass so per-run cost stays O(observations), not
 *  O(entities × observations) — the live doc grows every tick and
 *  the projection runs every tick. "First" matches the
 *  `event-helpers` find* semantics the rest of the app reads
 *  through. */
type ObservationIndex = {
  /** A row's ending is whichever of these arrived — a departure, the
   * identification that revealed it was a peer already on stage, or
   * the viewer losing sight of it. The row ends the same length
   * whichever it was; which one it was is the whole point of having
   * three kinds rather than one. */
  peers: Map<string, PeerRow>;
  /** Per temporal peer property, the moments each peer restated it,
   * as keyframes. A value a live feed states after the join (a chat
   * nick) holds from that observation's t onward, not over the whole
   * timeline. `trajectory.ts` names the properties; this index has
   * one map per property and learns nothing about them. */
  peerChanges: Map<PeerProperty, Map<string, Keyframe<string>[]>>;
  sessions: Map<string, SessionRow>;
  stateChanges: Map<string, Keyframe<SessionStateChanged["state"]>[]>;
  /** Per session end, the moments something attributed it to a peer,
   * as keyframes. Same shape as `peerChanges` one level up: a value
   * a live feed states after the open holds from that observation's
   * t onward, not over the whole session. Each keyframe carries the pair
   * the observation states — who is on the end, and what backed it — so a
   * mid-session attachment resolves to as much as a genesis one. */
  endpointChanges: Map<
    SessionSide,
    Map<string, Keyframe<EndpointAttachment>[]>
  >;
  messages: Map<string, MessageSent>;
};

function indexObservations(events: readonly TimelineEvent[]): ObservationIndex {
  const idx: ObservationIndex = {
    peers: new Map(),
    peerChanges: new Map(PEER_PROPERTIES.map((p) => [p, new Map()])),
    sessions: new Map(),
    stateChanges: new Map(),
    endpointChanges: new Map(SESSION_SIDES.map((s) => [s, new Map()])),
    messages: new Map(),
  };
  for (const ev of events) {
    switch (ev.kind) {
      case "peer-joined": {
        const row = idx.peers.get(ev.peerId);
        if (row === undefined) idx.peers.set(ev.peerId, { joined: ev });
        else if (row.joined === undefined) row.joined = ev;
        break;
      }
      case "peer-updated": {
        for (const { property, value } of peerUpdateStates(ev)) {
          const byPeer = idx.peerChanges.get(property);
          if (byPeer === undefined) continue;
          const track = byPeer.get(ev.peerId);
          if (track === undefined) {
            byPeer.set(ev.peerId, [{ t: ev.t, value }]);
          } else track.push({ t: ev.t, value });
        }
        break;
      }
      case "peer-unobserved": {
        const row = idx.peers.get(ev.peerId);
        if (row === undefined) idx.peers.set(ev.peerId, { unobserved: ev });
        else if (row.unobserved === undefined) row.unobserved = ev;
        break;
      }
      case "peer-left": {
        const row = idx.peers.get(ev.peerId);
        if (row === undefined) idx.peers.set(ev.peerId, { left: ev });
        else if (row.left === undefined) row.left = ev;
        break;
      }
      case "session-opened": {
        const row = idx.sessions.get(ev.sessionId);
        if (row === undefined) idx.sessions.set(ev.sessionId, { opened: ev });
        else if (row.opened === undefined) row.opened = ev;
        break;
      }
      case "session-closed": {
        const row = idx.sessions.get(ev.sessionId);
        if (row === undefined) idx.sessions.set(ev.sessionId, { closed: ev });
        else if (row.closed === undefined) row.closed = ev;
        break;
      }
      case "session-unobserved": {
        const row = idx.sessions.get(ev.sessionId);
        if (row === undefined) {
          idx.sessions.set(ev.sessionId, { unobserved: ev });
        } else if (row.unobserved === undefined) row.unobserved = ev;
        break;
      }
      case "session-state-changed": {
        const track = idx.stateChanges.get(ev.sessionId);
        if (track === undefined) {
          idx.stateChanges.set(ev.sessionId, [{ t: ev.t, value: ev.state }]);
        } else track.push({ t: ev.t, value: ev.state });
        break;
      }
      case "session-endpoint-attributed": {
        const bySession = idx.endpointChanges.get(ev.side);
        if (bySession === undefined) break;
        const value: EndpointAttachment = {
          peer: ev.peerId,
          ...(ev.attributedBy !== undefined &&
            { attributedBy: ev.attributedBy }),
        };
        const track = bySession.get(ev.sessionId);
        if (track === undefined) {
          bySession.set(ev.sessionId, [{ t: ev.t, value }]);
        } else track.push({ t: ev.t, value });
        break;
      }
      case "message-sent": {
        if (!idx.messages.has(ev.messageId)) {
          idx.messages.set(ev.messageId, ev);
        }
        break;
      }
    }
  }
  return idx;
}

function peerTiming(row: PeerRow | undefined): TimeSpan {
  const joined = row?.joined;
  // Either disposition ends the row, at whichever came first — a peer
  // that departed and one the viewer recognized as another peer both
  // stop being drawn from that moment.
  //
  // `event-helpers.peerEnding` answers the same question for readers
  // that hold a doc rather than this index, and the two are kept as
  // separate spellings on purpose: this one folds the whole stream
  // once per run (see the index note above), while a reader asking
  // about ONE peer cannot afford to. Change the rule and change both.
  const ended = firstEnding(row?.left, row?.unobserved);
  const start = joined ? explicitBound(joined.t) : implicitBound(0);
  const duration = ended && joined
    ? explicitBound(Math.max(0, ended.t - joined.t))
    : ended
    ? explicitBound(ended.t) // eternal-start, explicit end → start=0, duration=end
    : implicitBound(0);
  return markDerived({ start, duration });
}

function sessionTiming(row: SessionRow | undefined): TimeSpan {
  const opened = row?.opened;
  // A session's row ends when a producer saw it close, or when the
  // viewer stopped being able to see it — the same two-kinds-of-fact
  // split a peer's row has, and the span is the same either way.
  const ended = firstEnding(row?.closed, row?.unobserved);
  const start = opened ? explicitBound(opened.t) : implicitBound(0);
  const duration = ended && opened
    ? explicitBound(Math.max(0, ended.t - opened.t))
    : ended
    ? explicitBound(ended.t)
    : implicitBound(0);
  return markDerived({ start, duration });
}

function messageTiming(sent: MessageSent | undefined): TimeSpan {
  const start = sent ? explicitBound(sent.t) : implicitBound(0);
  // Messages: duration is ALWAYS explicit. Use the observed flight
  // (arrivalT − t) when a message-sent observation exists,
  // otherwise fall back to the default. `arrivalT === t` is the
  // live converter's "flight unobserved" sentinel and lands here
  // too — a zero flight is unobservable, so it takes the default
  // and the message visibly flies.
  const flight = sent
    ? Math.max(0, sent.arrivalT - sent.t) || DEFAULT_FLIGHT_MS
    : DEFAULT_FLIGHT_MS;
  return markDerived({ start, duration: explicitBound(flight) });
}

/** Value equality for the change gate — a re-derived span replaces
 *  the stored one only when it moved, so a quiet projection run
 *  keeps the doc object identity (the engine keys layout rebinds on
 *  it). Both sides are derived spans here, so the marker needs no
 *  comparing. */
function sameSpan(a: TimeSpan, b: TimeSpan): boolean {
  return a.start.value === b.start.value &&
    a.start.explicit === b.start.explicit &&
    a.duration.value === b.duration.value &&
    a.duration.explicit === b.duration.explicit;
}

/** One entity's observation-built keyframes, sorted by t (events
 *  can arrive out of order). Undefined when the entity has none. */
function trackFor<T>(
  tracks: Map<string, Keyframe<T>[]>,
  id: string,
): KeyframeTrack<T> | undefined {
  const out = tracks.get(id);
  if (out === undefined || out.length === 0) return undefined;
  return [...out].sort((a, b) => a.t - b.t);
}

/** The index carries a map per property, so a lookup cannot miss;
 *  this stands in for the one TypeScript still makes us handle. */
const NO_CHANGES: Map<string, Keyframe<never>[]> = new Map();

/** Value equality for a keyframe track — the change gate for a
 *  projection that re-derives tracks on every run. Two absent tracks
 *  are equal, so a peer nobody ever restated stays quiet.
 *
 *  `same` decides what "the same value" means, because not every track
 *  carries one: an endpoint keyframe is a pair, and comparing its halves is
 *  the property's own business (`SESSION_TRAJECTORY[side].same`). The
 *  default is identity, which is the whole of it for a track of words. */
function sameTrack<T>(
  a: KeyframeTrack<T> | undefined,
  b: KeyframeTrack<T> | undefined,
  same: (x: T, y: T) => boolean = (x, y) => x === y,
): boolean {
  if (a === undefined || b === undefined) return a === b;
  if (a.length !== b.length) return false;
  return a.every((kf, i) => kf.t === b[i]!.t && same(kf.value, b[i]!.value));
}

/** Synthesize a PeerDefinition from its peer-joined observation
 *  (which carries the identity payload). */
function synthesizePeerDef(
  joined: PeerJoined | undefined,
): PeerDefinition | undefined {
  if (!joined) return undefined;
  return {
    profile: joined.profile,
    ...(joined.label !== undefined ? { label: joined.label } : {}),
    ...(joined.designator !== undefined
      ? { designator: joined.designator }
      : {}),
    // NOTE: position deliberately NOT copied from the event.
    // Authored positions live on the event payload mutably (the
    // keyframe-layout system rewrites them for force-directed
    // layouts), so projecting that value into the entity def
    // would let the layout result poison the identity-side
    // record. The Engine writes the authored position to the
    // entity def directly via #definePeer; that path is the
    // source of truth for entity.position.
  };
}

function synthesizeSessionDef(
  opened: SessionOpened | undefined,
): SessionDefinition | undefined {
  if (!opened) return undefined;
  return {
    a: opened.a,
    b: opened.b,
    codec: opened.codec,
    captpVersion: opened.captpVersion,
    ...(opened.transport !== undefined ? { transport: opened.transport } : {}),
    ...(opened.initialState !== undefined
      ? { initialState: opened.initialState }
      : {}),
  };
}

function synthesizeMessageDef(
  sent: MessageSent | undefined,
): MessageDefinition | undefined {
  if (!sent) return undefined;
  return {
    sessionId: sent.sessionId,
    from: sent.from,
    to: sent.to,
    ...(sent.label !== undefined ? { label: sent.label } : {}),
    // Flight time is folded into timing.duration by messageTiming.
    // The wire payload stays on the observation — its one home; the
    // def carries identity, not bytes.
  };
}

/** Return a new doc with `timing` synthesized for any entity that
 *  doesn't carry one, derived `timing` re-derived from the current
 *  observations, plus entity-definition entries synthesized for any
 *  id mentioned by a creation observation but missing from
 *  `doc.entities`. Authored `timing` is preserved untouched.
 *  Idempotent over an unchanged observation set. */
export function projectFromObservations(
  doc: TimelineDocument,
): TimelineDocument {
  // Cast is safe: Observation and TimelineEvent share their wire
  // shape (TimelineEvent is the writer-side name; Observation is
  // the reader-side name on the recording).
  const events = observationsOf(doc) as readonly TimelineEvent[];
  const idx = indexObservations(events);

  const seedPeers: Record<string, PeerDefinition> = {
    ...(doc.entities?.peers ?? {}),
  };
  const seedSessions: Record<string, SessionDefinition> = {
    ...(doc.entities?.sessions ?? {}),
  };
  const seedMessages: Record<string, MessageDefinition> = {
    ...(doc.entities?.messages ?? {}),
  };
  let touched = false;
  for (const [id, row] of idx.peers) {
    if (seedPeers[id] !== undefined) continue;
    const synth = synthesizePeerDef(row.joined);
    if (synth !== undefined) {
      seedPeers[id] = synth;
      touched = true;
    }
  }
  for (const [id, row] of idx.sessions) {
    if (seedSessions[id] !== undefined) continue;
    const synth = synthesizeSessionDef(row.opened);
    if (synth !== undefined) {
      seedSessions[id] = synth;
      touched = true;
    }
  }
  for (const [id, sent] of idx.messages) {
    if (seedMessages[id] !== undefined) continue;
    const synth = synthesizeMessageDef(sent);
    if (synth !== undefined) {
      seedMessages[id] = synth;
      touched = true;
    }
  }

  /** Shared span rule: authored wins outright; a missing or derived
   *  span re-derives, replacing only on real change. */
  const projectSpan = (
    def: { timing?: TimeSpan | undefined },
    next: TimeSpan,
  ): TimeSpan | null => {
    const cur = def.timing;
    if (cur !== undefined && !isDerived(cur)) return null; // authored
    if (cur !== undefined && sameSpan(cur, next)) return null; // unchanged
    return next;
  };

  const projectPeer = (id: string, def: PeerDefinition): PeerDefinition => {
    const nextTiming = projectSpan(def, peerTiming(idx.peers.get(id)));
    // Each moment a peer restated something becomes a keyframe at
    // its own t, so the peer carries the value it had then and a
    // replay shows the sequence the live viewer saw. Every property
    // in `PEER_TRAJECTORY` folds the same way, and the tracks
    // re-derive on every run — that is how a live annotation lands
    // the tick it arrives, and how an observation the author deleted
    // takes its keyframe with it. Authored edits write the
    // observations (`authoring/peer.ts`), so they survive the
    // re-derivation.
    let next: PeerDefinition = def;
    for (const property of PEER_PROPERTIES) {
      const spec = PEER_TRAJECTORY[property];
      const track = trackFor(idx.peerChanges.get(property) ?? NO_CHANGES, id);
      if (sameTrack(spec.track(next), track)) continue;
      const keyframes = spec.withTrack(next, track);
      next = { ...next };
      if (keyframes === undefined) delete next.keyframes;
      else next.keyframes = keyframes;
    }
    const trackChanged = next !== def;
    if (nextTiming === null && !trackChanged) return def;
    touched = true;
    if (!trackChanged) next = { ...def };
    if (nextTiming !== null) next.timing = nextTiming;
    return next;
  };
  const projectSession = (
    id: string,
    def: SessionDefinition,
  ): SessionDefinition => {
    const nextTiming = projectSpan(def, sessionTiming(idx.sessions.get(id)));
    // Build the kfs track from observations only when the def
    // doesn't already carry one — tracks have no provenance marker
    // yet (see module header).
    const stateTrack = def.keyframes?.state === undefined
      ? trackFor(idx.stateChanges, id)
      : undefined;
    // The endpoint tracks re-derive on every run, the way a peer's
    // name track does and unlike the state track beside them: an
    // attribution IS a live arrival, and a track kept after its first
    // derivation would leave the end loose after something attributed
    // it.
    let endpoints: SessionDefinition["keyframes"] | undefined;
    for (const side of SESSION_SIDES) {
      const bySession = idx.endpointChanges.get(side) ?? NO_CHANGES;
      const track = trackFor(bySession, id);
      // What "the same attachment" means belongs to the property, not here:
      // an end's value is a pair and both halves count.
      const same = SESSION_TRAJECTORY[side].same;
      if (sameTrack(def.keyframes?.[side], track, same)) continue;
      endpoints = { ...(endpoints ?? def.keyframes) };
      if (track === undefined) delete endpoints[side];
      else endpoints[side] = [...track];
    }
    if (
      nextTiming === null && stateTrack === undefined && endpoints === undefined
    ) return def;
    touched = true;
    const next: SessionDefinition = { ...def };
    if (nextTiming !== null) next.timing = nextTiming;
    if (endpoints !== undefined) next.keyframes = endpoints;
    if (stateTrack !== undefined) {
      next.keyframes = { ...next.keyframes, state: [...stateTrack] };
    }
    return next;
  };
  const projectMessage = (
    id: string,
    def: MessageDefinition,
  ): MessageDefinition => {
    const next = projectSpan(def, messageTiming(idx.messages.get(id)));
    if (next === null) return def;
    touched = true;
    return { ...def, timing: next };
  };

  const peers = Object.keys(seedPeers).length > 0
    ? Object.fromEntries(
      Object.entries(seedPeers).map(
        ([id, def]) => [id, projectPeer(id, def)] as const,
      ),
    )
    : undefined;
  const sessions = Object.keys(seedSessions).length > 0
    ? Object.fromEntries(
      Object.entries(seedSessions).map(
        ([id, def]) => [id, projectSession(id, def)] as const,
      ),
    )
    : undefined;
  const messages = Object.keys(seedMessages).length > 0
    ? Object.fromEntries(
      Object.entries(seedMessages).map(
        ([id, def]) => [id, projectMessage(id, def)] as const,
      ),
    )
    : undefined;

  if (!touched) return doc;
  return {
    ...doc,
    entities: {
      ...(peers && { peers }),
      ...(sessions && { sessions }),
      ...(messages && { messages }),
    },
  };
}
