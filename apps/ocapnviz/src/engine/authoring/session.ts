/**
 * Session-level authoring operations. Each function takes the
 * `AuthoringContext` as its first argument.
 */

import type { CaptpVersion, Codec, SessionState, Transport } from "../../schema/topology.ts";
import {
  type EndpointAttribution,
  type SessionEndpoint,
  sessionEndpoint,
  type SessionSide,
} from "../../schema/session-end.ts";
import { patchSessionDefinition } from "../entities.ts";
import { cascadeDelete } from "../schema/cascade.ts";
import { restoreSnapshotInto, takeSnapshot } from "../snapshot.ts";
import { implicitBound } from "../temporal/bound.ts";
import { peerEffective, sessionEffective } from "../temporal/doc-resolver.ts";
import { clearDuration, clearStart, setDuration, setStart } from "../temporal/time-span.ts";
import { removeKeyframe, setKeyframe } from "../temporal/keyframes.ts";
import { observationsOf } from "../temporal/recording-access.ts";
import type { TimelineEvent } from "../timeline.ts";
import { notFoundError, validationError } from "../errors.ts";
import { SESSION_TRAJECTORY, type SessionProperty, type SessionValue } from "../trajectory.ts";
import type { AuthoringContext } from "./context.ts";
import { bumpEntities, commitEntityAuthoring, removeObservations, upsertObservation } from "./events.ts";

/** The observation stating one of a session's properties at exactly
 *  `t` — what a keyframe write replaces and a removal drops. The
 *  property itself says which observations state it, so this predicate
 *  is the same shape for a state change and for an end attaching. */
const momentAt = (property: SessionProperty, sessionId: string, t: number) => (ev: TimelineEvent): boolean =>
  ev.t === t && SESSION_TRAJECTORY[property].read(ev, sessionId) !== null;

function defaultSessionTiming() {
  return { start: implicitBound(0), duration: implicitBound(0) };
}

// Each sync helper writes through a `time-span.ts` authoring op —
// the one vocabulary that produces authored spans (a derived span
// loses its marker here, so projection stops re-deriving it).

function syncSessionDuration(
  ctx: AuthoringContext,
  sessionId: string,
  duration: number,
): void {
  const def = ctx.doc.entities?.sessions?.[sessionId];
  if (!def) return;
  def.timing = setDuration(def.timing ?? defaultSessionTiming(), duration);
}

function syncSessionEndCleared(
  ctx: AuthoringContext,
  sessionId: string,
): void {
  const def = ctx.doc.entities?.sessions?.[sessionId];
  if (!def) return;
  def.timing = clearDuration(def.timing ?? defaultSessionTiming());
}

function syncSessionStart(
  ctx: AuthoringContext,
  sessionId: string,
  startT: number,
): void {
  const def = ctx.doc.entities?.sessions?.[sessionId];
  if (!def) return;
  def.timing = setStart(def.timing ?? defaultSessionTiming(), startT);
}

function syncSessionStartCleared(
  ctx: AuthoringContext,
  sessionId: string,
): void {
  const def = ctx.doc.entities?.sessions?.[sessionId];
  if (!def) return;
  def.timing = clearStart(def.timing ?? defaultSessionTiming());
}

/** Remove a session and everything that depends on it. Cascades
 * through `cascadeDelete` — message events, message entities on
 * this session, the session itself, and every doc-level index
 * containing any of the removed ids. */
export function deleteSession(
  ctx: AuthoringContext,
  sessionId: string,
): void {
  const next = cascadeDelete(ctx.doc, "session", sessionId);
  restoreSnapshotInto(ctx.doc, takeSnapshot(next));
  ctx.seekTo(ctx.clock.t);
}

/** Patch session-level fields.
 *
 * - `codec` / `captpVersion` / `transport` are what the session is,
 *   not things that change mid-life, so each is written to the
 *   session's definition. `transport` takes `null` to stop stating
 *   one, because a session whose netlayer nothing named is a shape the
 *   document holds and an author has to be able to reach it.
 * - `state` is timeline-shaped: a non-undefined value inserts a
 *   `session-state-changed` event at `clock.t` (Flash convention —
 *   the playhead is where you author). If you want to fix the
 *   genesis state, edit `initialState` directly on the
 *   `session-opened` event via a future intent; this path won't
 *   touch it. */
export function updateSession(
  ctx: AuthoringContext,
  sessionId: string,
  patch: {
    codec?: Codec;
    captpVersion?: CaptpVersion;
    transport?: Transport | null;
    state?: SessionState;
  },
): void {
  // Codec / captpVersion / transport are identity → entities map.
  if (
    patch.codec !== undefined || patch.captpVersion !== undefined ||
    patch.transport !== undefined
  ) {
    const defPatch: {
      codec?: Codec;
      captpVersion?: CaptpVersion;
      transport?: Transport | null;
    } = {};
    if (patch.codec !== undefined) defPatch.codec = patch.codec;
    if (patch.captpVersion !== undefined) {
      defPatch.captpVersion = patch.captpVersion;
    }
    if (patch.transport !== undefined) defPatch.transport = patch.transport;
    patchSessionDefinition(ctx.doc, sessionId, defPatch);
  }
  // State changes over time, so a patched state is a moment at the
  // playhead — the same write a trajectory row makes, through the same
  // op, so the two cannot disagree about where a state change is kept.
  if (patch.state !== undefined) {
    setSessionKeyframe(ctx, sessionId, "state", ctx.clock.t, patch.state);
  }
  // The identity path patches the definition directly, without
  // commitEntityAuthoring, so bump the entities reference here too —
  // otherwise downstream WeakMap caches (e.g. the Scrubber
  // lane-bundle cache) miss the mutation and segments don't repaint.
  bumpEntities(ctx);
  ctx.seekTo(ctx.clock.t);
}

/** Set the session's start time. Mutates entity.timing.start. */
export function setSessionStart(
  ctx: AuthoringContext,
  sessionId: string,
  t: number,
): void {
  const def = ctx.doc.entities?.sessions?.[sessionId];
  if (!def) {
    ctx.emitError(notFoundError("session", sessionId));
    return;
  }
  // Only an attached end has a peer whose arrival can bound the session; a
  // loose end has nobody to wait for.
  const peerStart = Math.max(
    ...[def.a.peer, def.b.peer]
      .filter((p): p is string => p !== undefined)
      .map((p) => peerEffective(ctx.doc, p).start),
    Number.NEGATIVE_INFINITY,
  );
  if (t < peerStart) {
    ctx.emitError(validationError(
      `Session start (${t}) is before both endpoints exist (earliest ${peerStart}).`,
      "Move the session start after both peers join, or move the peers earlier.",
    ));
    return;
  }
  const effEnd = sessionEffective(ctx.doc, sessionId).end;
  if (Number.isFinite(effEnd) && t > effEnd) {
    ctx.emitError(validationError(
      `Session start (${t}) is after its end (${effEnd}).`,
      "Move the start before the end, or clear the end first.",
    ));
    return;
  }
  syncSessionStart(ctx, sessionId, t);
  commitEntityAuthoring(ctx, t);
}

/** Restore implicit start (inherits max(peerA.start, peerB.start)). */
export function clearSessionStart(
  ctx: AuthoringContext,
  sessionId: string,
): void {
  syncSessionStartCleared(ctx, sessionId);
  commitEntityAuthoring(ctx);
}

/** Set the session's duration. Mutates entity.timing.duration directly —
 *  the storage-shaped intent matching the TimeSpan model. */
export function setSessionDuration(
  ctx: AuthoringContext,
  sessionId: string,
  duration: number,
): void {
  const def = ctx.doc.entities?.sessions?.[sessionId];
  if (!def) {
    ctx.emitError(notFoundError("session", sessionId));
    return;
  }
  if (!(duration >= 0)) {
    ctx.emitError(validationError(
      `Session duration must be ≥ 0 (got ${duration}).`,
      "Drag the duration handle forward, or type a non-negative value.",
    ));
    return;
  }
  syncSessionDuration(ctx, sessionId, duration);
  commitEntityAuthoring(ctx, sessionEffective(ctx.doc, sessionId).end);
}

/** End-flavored wrapper. Translates absolute `t` to a duration off the
 *  session's effective start, then defers to `setSessionDuration`. */
export function setSessionEnd(
  ctx: AuthoringContext,
  sessionId: string,
  t: number,
): void {
  const def = ctx.doc.entities?.sessions?.[sessionId];
  if (!def) {
    ctx.emitError(notFoundError("session", sessionId));
    return;
  }
  const start = sessionEffective(ctx.doc, sessionId).start;
  if (t < start) {
    ctx.emitError(validationError(
      `Session end (${t}) is before its start (${start}).`,
      "Move the end after the start, or clear the start first.",
    ));
    return;
  }
  setSessionDuration(ctx, sessionId, t - start);
}

/** Restore implicit (stays-open) end. */
export function clearSessionEnd(
  ctx: AuthoringContext,
  sessionId: string,
): void {
  syncSessionEndCleared(ctx, sessionId);
  commitEntityAuthoring(ctx);
}

/** State `value` for one of the session's temporal properties from
 *  `t` onward, replacing what it stated about that property at `t`.
 *  This is the trajectory-edit primitive the Inspector list calls per
 *  row: a state change, or one end attaching to a peer.
 *
 *  The write always mints the observation, because that is what a
 *  moment IS in the recording, and additionally writes the definition
 *  track for the property whose track is durable there. Which
 *  properties exist, what observation carries one, and where its track
 *  lives are all `trajectory.ts`'s business — this op learns none of
 *  them.
 *
 *  The value the session is BORN with is not a moment:
 *  `setSessionInitialState` edits the genesis state, and
 *  `updateSessionEndpoint` the genesis end. */
export function setSessionKeyframe(
  ctx: AuthoringContext,
  sessionId: string,
  property: SessionProperty,
  t: number,
  value: SessionValue,
): void {
  const def = ctx.doc.entities?.sessions?.[sessionId];
  if (!def) {
    ctx.emitError(notFoundError("session", sessionId));
    return;
  }
  const spec = SESSION_TRAJECTORY[property];
  // One read of what the write carried into the value the track stores, so
  // the observation and the definition track cannot state two different
  // things, and the checks below judge the value that will actually land.
  const parsed = spec.parse(value);
  const start = sessionEffective(ctx.doc, sessionId).start;
  if (t < start) {
    ctx.emitError(validationError(
      `A new ${spec.noun} at ${t} is before the session opens (${start}).`,
      "Drop the change inside the session's lifetime, or move the session start earlier.",
    ));
    return;
  }
  // A property whose value names an entity refuses one the document
  // does not declare: a keyframe attaching an end to a peer that is
  // not there is a reference pointing at nothing, and every other
  // reference site in the document is checked (`schema/edges.ts`). The
  // name is read through `stated`, which is the property's own answer to
  // "which entity is this value about" — an end's value is a pair, and
  // only half of it is the reference.
  const named = spec.stated(parsed);
  if (
    spec.names === "peers" && ctx.doc.entities?.peers?.[named] === undefined
  ) {
    ctx.emitError(notFoundError("peer", named));
    return;
  }
  upsertObservation(
    ctx,
    momentAt(property, sessionId, t),
    spec.observation(`auth-${ctx.mintId()}`, sessionId, t, parsed),
  );
  if (spec.withTrack !== undefined) {
    def.keyframes = spec.withTrack(
      def,
      setKeyframe(spec.track(def), t, parsed),
    );
  }
  commitEntityAuthoring(ctx, t);
}

/** Stop stating one property at exactly `t`. No-op when it stated
 *  nothing there. Clearing an end's moment is how an end that
 *  attached comes loose again — the attachment stops having
 *  happened, and nothing else about the session moves. */
export function removeSessionKeyframe(
  ctx: AuthoringContext,
  sessionId: string,
  property: SessionProperty,
  t: number,
): void {
  const def = ctx.doc.entities?.sessions?.[sessionId];
  if (!def) return;
  const spec = SESSION_TRAJECTORY[property];
  removeObservations(ctx, momentAt(property, sessionId, t));
  if (spec.withTrack !== undefined) {
    def.keyframes = spec.withTrack(def, removeKeyframe(spec.track(def), t));
  }
  commitEntityAuthoring(ctx);
}

/** Edit one end of a session as it is BORN — what it claims to be,
 *  the peer it is attached to, and what attributed it. Row 0 of the
 *  end's trajectory, the way `setSessionInitialState` is row 0 of the
 *  state's; a later attachment is a moment and goes through
 *  `setSessionKeyframe`.
 *
 *  Each field is optional, and `null` clears it: an end with no
 *  `peer` is loose, which is an ordinary state of the network rather
 *  than a missing value.
 *
 *  The three patches resolve against the end's three current values and the
 *  result is built by `sessionEndpoint`, so the one-way invariant is the
 *  `EndpointParts` union rather than a rule restated here: an end left with
 *  no peer has no field an attribution could go in. What this op adds is the
 *  reading of a patch that would need one — attributing an end attached to
 *  nobody is refused with a message, and detaching an attributed end takes
 *  the attribution with it rather than failing. */
export function updateSessionEndpoint(
  ctx: AuthoringContext,
  sessionId: string,
  side: SessionSide,
  patch: {
    peer?: string | null;
    designator?: string | null;
    attributedBy?: EndpointAttribution | null;
  },
): void {
  const def = ctx.doc.entities?.sessions?.[sessionId];
  if (!def) {
    ctx.emitError(notFoundError("session", sessionId));
    return;
  }
  const current = def[side];
  let peer = current.peer;
  if (patch.peer === null) peer = undefined;
  else if (patch.peer !== undefined) {
    if (ctx.doc.entities?.peers?.[patch.peer] === undefined) {
      ctx.emitError(notFoundError("peer", patch.peer));
      return;
    }
    peer = patch.peer;
  }
  // An empty claim is no claim, the same reading a peer's identifier
  // field takes of an emptied input.
  let designator = current.designator;
  if (patch.designator === null || patch.designator === "") {
    designator = undefined;
  } else if (patch.designator !== undefined) designator = patch.designator;
  let attributedBy = current.attributedBy;
  if (patch.attributedBy === null) attributedBy = undefined;
  else if (patch.attributedBy !== undefined) attributedBy = patch.attributedBy;
  if (peer === undefined) {
    // Asking for an attribution on an end attached to nobody is a mistake
    // worth a message. Carrying one over from before the detach is not: the
    // author moved the end off its peer, and the evidence went with it.
    if (patch.attributedBy !== undefined && patch.attributedBy !== null) {
      ctx.emitError(validationError(
        "Nothing can attribute an end to nobody.",
        "Attach the end to a peer first, then say what attributed it.",
      ));
      return;
    }
    attributedBy = undefined;
  }
  const next: SessionEndpoint = sessionEndpoint(
    peer === undefined ? { designator } : { peer, designator, attributedBy },
  );
  def[side] = next;
  // Mirror onto the opening observation so the recording says what the
  // definition says, exactly as a peer's identity edit mirrors onto
  // its join.
  for (const ev of observationsOf(ctx.doc) as TimelineEvent[]) {
    if (ev.kind !== "session-opened" || ev.sessionId !== sessionId) continue;
    ev[side] = next;
  }
  commitEntityAuthoring(ctx);
}

/** Edit the session's genesis state (`entities.sessions[id].initialState`).
 *  This is row 0 of the trajectory — the value the session is born
 *  with, before any keyframe takes effect. */
export function setSessionInitialState(
  ctx: AuthoringContext,
  sessionId: string,
  state: SessionState,
): void {
  patchSessionDefinition(ctx.doc, sessionId, { initialState: state });
  commitEntityAuthoring(ctx);
}
