/**
 * Event-level authoring primitives — insert / remove / retime
 * `TimelineEvent`s in the doc's primary recording source (via
 * `primaryObservations`). Used by the higher-level
 * peer/session/message authoring modules and by callers (live-feed)
 * that need to push authored observations without the per-category
 * orchestration.
 */

import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import { checkDeliveredOrdering, checkMoveOrdering } from "../event-helpers.ts";
import { messageEffective, peerEffective, sessionEffective } from "../temporal/doc-resolver.ts";
import { observationsOf, primaryObservations } from "../temporal/recording-access.ts";
import { asAuthored, setSpanEndAt, setSpanStartAt, type TimeSpan, translateSpan } from "../temporal/time-span.ts";
import { implicitBound } from "../temporal/bound.ts";
import { notFoundError, validationError } from "../errors.ts";
import { SESSION_TRAJECTORY, sessionMomentOf } from "../trajectory.ts";
import type { AuthoringContext } from "./context.ts";

/** Extend `doc.duration` (and the clock's bound) to cover `event`.
 * Internal — every event-insertion path calls this so the playable
 * range always covers what the timeline can paint. */
export function growDurationToFit(
  ctx: AuthoringContext,
  event: TimelineEvent,
): void {
  const need = event.kind === "message-sent" ? Math.max(event.t, event.arrivalT) : event.t;
  if (need <= ctx.doc.duration) return;
  (ctx.doc as { duration: number }).duration = need;
  ctx.clock.setDuration(need);
}

/**
 * The last moment this document states anything at.
 *
 * `growDurationToFit` above asks this of one event; this asks it of the whole
 * document, and the two sit together so they cannot disagree about what counts.
 * It is the floor a duration may not go below: a timeline shorter than its own
 * last event hides that event behind an end the scrubber cannot travel past.
 *
 * Stated times, not effective ranges. An effective end is unbounded for anything
 * that never leaves — a peer that joins and stays runs to infinity — so a maximum
 * over those would answer infinity for most documents. What a duration has to
 * cover is where the marks are.
 *
 * Entity timing is read as well as observations, because a Build-authored entity
 * may state a window no observation mentions.
 */
export function latestStatedTime(doc: TimelineDocument): number {
  let latest = 0;
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    latest = Math.max(latest, ev.t);
    if (ev.kind === "message-sent") latest = Math.max(latest, ev.arrivalT);
  }
  for (const group of ["peers", "sessions", "messages"] as const) {
    for (const def of Object.values(doc.entities?.[group] ?? {})) {
      const timing = (def as { timing?: TimeSpan }).timing;
      if (!timing) continue;
      const start = timing.start.value;
      const end = start + timing.duration.value;
      if (Number.isFinite(start)) latest = Math.max(latest, start);
      if (Number.isFinite(end)) latest = Math.max(latest, end);
    }
  }
  return latest;
}

/** Post-mutation orchestration for entity-shaped authoring edits
 *  (timing / keyframes mutated directly on doc.entities, no event
 *  inserted). Grows doc duration to cover the latest t the change
 *  reaches, recomputes the layout so new topology entries get a
 *  keyframe, and seeks to refresh the world. Use after any
 *  syncPeer* / syncSession* / syncMessage* helper. */
export function commitEntityAuthoring(
  ctx: AuthoringContext,
  growToT?: number,
): void {
  if (growToT !== undefined && growToT > ctx.doc.duration) {
    (ctx.doc as { duration: number }).duration = growToT;
    ctx.clock.setDuration(growToT);
  }
  // Bump entities reference so downstream WeakMap caches (e.g. the
  // Scrubber lane-bundle cache) invalidate. Entity authoring mutates
  // `doc.entities` in place; without this swap, viewer caches keyed
  // on identity keep painting the pre-edit shape.
  bumpEntities(ctx);
  ctx.recomputeLayout();
  ctx.seekTo(ctx.clock.t);
}

/** Insert `event` into the primary recording source at the right sorted position,
 * grow the doc duration to cover it, recompute keyframe layout (so
 * any new topology entity has a position), and seek the clock so
 * the world reflects the new doc on the next paint.
 *
 * Used today only by live-feed (incoming observations over the live websocket).
 * Authoring intents mutate entity.timing / keyframes directly via
 * `commitEntityAuthoring`. */
export function applyAuthored(
  ctx: AuthoringContext,
  event: TimelineEvent,
): void {
  const events = primaryObservations(ctx.doc);
  let insertAt = events.length;
  for (let i = 0; i < events.length; i++) {
    if (events[i]!.t > event.t) {
      insertAt = i;
      break;
    }
  }
  events.splice(insertAt, 0, event);
  growDurationToFit(ctx, event);
  // New topology-changing events need a keyframe recompute so the
  // layout has an entry for them; otherwise `layout.update` leaves
  // them at the `applyEvent` default of (0, 0).
  ctx.recomputeLayout();
  ctx.seekTo(ctx.clock.t);
}

/** Drop every observation `matches` claims. Returns how many went,
 *  so a caller can tell a real removal from a no-op. */
export function removeObservations(
  ctx: AuthoringContext,
  matches: (ev: TimelineEvent) => boolean,
): number {
  const events = primaryObservations(ctx.doc);
  let removed = 0;
  for (let i = events.length - 1; i >= 0; i--) {
    if (!matches(events[i]!)) continue;
    events.splice(i, 1);
    removed += 1;
  }
  return removed;
}

/** Put `event` in the observation stream at its sorted position,
 *  replacing whatever `matches` claims first. The one write behind
 *  every "a moment happened here" authoring op — a session's state
 *  change, a peer's update — so the two cannot drift in how the
 *  stream is kept sorted or how a moment at the same t is replaced.
 *  The stream stays sorted by `t`; the caller commits.
 *
 *  A replacement KEEPS the id of the moment it replaces: it is the
 *  same moment carrying a new value, and everything that addresses a
 *  moment addresses it by that id — the Inspector row's React key,
 *  the timeline's focus halo, an open drag. Minting a fresh id on
 *  each write tears the row out from under the user: typing one
 *  character into a trajectory row's value field remounted the input
 *  and took the focus with it. */
export function upsertObservation(
  ctx: AuthoringContext,
  matches: (ev: TimelineEvent) => boolean,
  event: TimelineEvent,
): void {
  const existingId = primaryObservations(ctx.doc).find(matches)?.id;
  removeObservations(ctx, matches);
  const events = primaryObservations(ctx.doc);
  if (existingId !== undefined) event = { ...event, id: existingId };
  let insertAt = events.length;
  for (let i = 0; i < events.length; i++) {
    if (events[i]!.t > event.t) {
      insertAt = i;
      break;
    }
  }
  events.splice(insertAt, 0, event);
}

/** Entity-doc rewrite paired with a `move-event` observation move.
 *  Built at plan time from the pre-move doc state so reading layer 3
 *  (effective) ranges still sees the gesture's "from" side, then
 *  applied after the observation mutation. New patch kinds get added
 *  here and a branch in `applyPatch`. */
export type MovePatch =
  | { kind: "peer-timing"; peerId: string; span: TimeSpan }
  | { kind: "session-timing"; sessionId: string; span: TimeSpan }
  | { kind: "message-timing"; messageId: string; span: TimeSpan }
  | {
    kind: "session-keyframe-move";
    sessionId: string;
    oldT: number;
    newT: number;
  };

function applyPatch(ctx: AuthoringContext, patch: MovePatch): void {
  // `asAuthored`: a patched span is user intent, so it must not
  // carry the projection's derived marker — this funnel assigns
  // spans it did not build, and a marker slipping through would let
  // projection clobber the user's gesture on the next tick.
  if (patch.kind === "peer-timing") {
    const def = ctx.doc.entities?.peers?.[patch.peerId];
    if (def) def.timing = asAuthored(patch.span);
    return;
  }
  if (patch.kind === "session-timing") {
    const def = ctx.doc.entities?.sessions?.[patch.sessionId];
    if (def) def.timing = asAuthored(patch.span);
    return;
  }
  if (patch.kind === "message-timing") {
    const def = ctx.doc.entities?.messages?.[patch.messageId];
    if (def) def.timing = asAuthored(patch.span);
    return;
  }
  // session-keyframe-move: rewrite the kf entry whose t matches
  // patch.oldT, reinserting at the sorted position for patch.newT.
  const def = ctx.doc.entities?.sessions?.[patch.sessionId];
  const track = def?.keyframes?.state;
  if (!def || !track) return;
  const ki = track.findIndex((kf) => kf.t === patch.oldT);
  if (ki === -1) return;
  const next = [...track];
  const kf = next[ki]!;
  next.splice(ki, 1);
  let insertAt = next.length;
  for (let i = 0; i < next.length; i++) {
    if (next[i]!.t > patch.newT) {
      insertAt = i;
      break;
    }
  }
  next.splice(insertAt, 0, { t: patch.newT, value: kf.value });
  def.keyframes = { ...def.keyframes, state: next };
}

/** Drag gesture against an event. Each variant encodes exactly the
 *  inputs that gesture needs — no booleans that "only matter for
 *  message-sent", no optional `arrivalT` that flips the meaning of
 *  `newT` from "body anchor" to "left edge". The engine narrows on
 *  `kind` to pick the right span-edge writer; an invalid pairing
 *  (e.g. `resize-end` on a peer event) is unrepresentable.
 *
 *  - `translate`: body slide. For message-sent the paired delivered
 *    auto-slides by the same dt (flight time preserved); for
 *    peer-joined and session-opened, every event scoped to the same
 *    entity slides by dt.
 *  - `resize-start`: left-edge resize. For peer-joined and
 *    session-opened, only the start moves and the paired close
 *    stays put. For message-sent, sent moves and arrival stays
 *    pinned.
 *  - `resize-end`: message-only — sent stays, arrival moves to
 *    `newArrivalT`. Span-shaped peers/sessions resize on the right
 *    by `translate`-ing the close event (peer-left, session-closed)
 *    directly, since the close event IS the right edge. */
export type MoveIntent =
  | { kind: "translate"; eventId: string; newT: number }
  | { kind: "resize-start"; eventId: string; newT: number }
  | { kind: "resize-end"; eventId: string; newArrivalT: number };

/** A span-shaped entity a timeline drag can retime — peer or session.
 *  Messages stay event-addressed: a message always has its
 *  `message-sent` observation, so the event path covers it. */
export type SpanRef = { kind: "peer" | "session"; id: string };

/** Drag gesture against an entity's span, addressed by the entity
 *  itself rather than an observation event. This is what makes a
 *  freshly authored entity — which has `entity.timing` but no
 *  observation events yet — retimeable exactly like a loaded one:
 *  the gesture names the span, and whatever observations exist are
 *  kept in sync as a consequence, not consulted as a precondition.
 *
 *  `newT` is the new time of the edge the gesture drives: the span
 *  start for `translate` and `resize-start`, the span end for
 *  `resize-end`. */
export type MoveSpanIntent = {
  kind: "translate" | "resize-start" | "resize-end";
  ref: SpanRef;
  newT: number;
};

/** Retime an event without changing its shape. Foundation for
 * timeline-drag editing.
 *
 * The render reads `entity.timing`, not the observation log, so
 * every gesture also writes `timing.start` / `timing.duration` (and
 * `keyframes.state` for session-state-changed pair-slides). Without
 * that dual-write the user drags the pill and nothing appears to
 * happen because the projected span stays put.
 *
 * Validates against ordering constraints (peer-left after
 * peer-joined, session-state-changed after session-opened,
 * message-delivered after message-sent, etc.) and rejects invalid
 * moves via the engine error channel. Auto-extends `doc.duration` if the
 * new time(s) exceed the current end. */
export function moveEvent(
  ctx: AuthoringContext,
  intent: MoveIntent,
): void {
  const events = primaryObservations(ctx.doc);
  const idx = events.findIndex((e) => e.id === intent.eventId);
  if (idx === -1) return;
  const ev = events[idx]!;
  // resize-end's anchor is `newArrivalT`; translate / resize-start
  // both work off `newT`. Resolve once for the validation gate.
  const anchorT = intent.kind === "resize-end" ? intent.newArrivalT : intent.newT;
  if (anchorT < 0) {
    ctx.emitError(validationError(
      `Event time (${anchorT}) is before the timeline start.`,
      "Drop the event at t ≥ 0.",
    ));
    return;
  }

  // Build the move plan. Two pieces, paired so a future reader sees
  // them as one gesture:
  //   - `moves`: observation mutations (anchor + pair-slides).
  //   - `patches`: every entity-doc rewrite needed to keep the
  //     renderer's read of `entity.timing` / `entity.keyframes`
  //     agreeing with the gesture. Built from the pre-move state,
  //     applied after observations are mutated.
  // All patch computation reads pre-move effective ranges, so it
  // MUST happen before the observation-apply loop.
  type Move =
    & { ev: TimelineEvent; newT: number }
    & ({ newArrivalT?: number } | Record<string, never>);
  const moves: Move[] = [];
  const patches: MovePatch[] = [];

  if (ev.kind === "message-sent") {
    let newT: number;
    let newArrivalT: number;
    if (intent.kind === "translate") {
      const dt = intent.newT - ev.t;
      newT = intent.newT;
      newArrivalT = ev.arrivalT + dt;
    } else if (intent.kind === "resize-start") {
      newT = intent.newT;
      newArrivalT = ev.arrivalT;
    } else {
      newT = ev.t;
      newArrivalT = intent.newArrivalT;
    }
    if (newArrivalT < newT) {
      ctx.emitError(validationError(
        `Arrival (${newArrivalT}) cannot precede the send (${newT}).`,
        "Move arrival after the send, or move the send earlier.",
      ));
      return;
    }
    moves.push({ ev, newT, newArrivalT });
    const delivered = events.find(
      (e) => e.kind === "message-delivered" && e.messageId === ev.messageId,
    );
    if (delivered) moves.push({ ev: delivered, newT: newArrivalT });
    const def = ctx.doc.entities?.messages?.[ev.messageId];
    if (def?.timing) {
      const eff = messageEffective(ctx.doc, ev.messageId);
      // Translate dt is measured against the painted start, not the
      // observation's t — the two can differ after a storage-shaped
      // Inspector edit, and the pill must land where the gesture
      // dropped it. The observation itself still moves to `newT`.
      const span = intent.kind === "resize-start"
        ? setSpanStartAt(def.timing, newT, eff.end)
        : intent.kind === "resize-end"
        ? setSpanEndAt(eff.start, newArrivalT)
        : translateSpan(def.timing, newT - eff.start, eff.start, eff.end);
      patches.push({
        kind: "message-timing",
        messageId: ev.messageId,
        span,
      });
    }
  } else if (ev.kind === "peer-joined") {
    if (intent.kind === "resize-end") {
      ctx.emitError(validationError(
        "Right-edge resize on peer-joined is not supported.",
        "Drag the peer-left event instead — it is the right edge.",
      ));
      return;
    }
    const newT = intent.newT;
    const dt = newT - ev.t;
    moves.push({ ev, newT });
    if (intent.kind === "translate") {
      // The whole peer moves: its departure and every update keep
      // their spacing from the join, the way a session's state
      // changes ride along with it below. An update needs no keyframe
      // patch beside the move — the projection re-derives every
      // property's track from these observations on the next run.
      for (const e of events) {
        if (e === ev) continue;
        if (
          (e.kind === "peer-left" || e.kind === "peer-updated") &&
          e.peerId === ev.peerId
        ) {
          moves.push({ ev: e, newT: e.t + dt });
        }
      }
    }
    const def = ctx.doc.entities?.peers?.[ev.peerId];
    if (def?.timing) {
      const eff = peerEffective(ctx.doc, ev.peerId);
      // Painted-start dt for the span patch; see the message branch.
      patches.push({
        kind: "peer-timing",
        peerId: ev.peerId,
        span: intent.kind === "resize-start"
          ? setSpanStartAt(def.timing, newT, eff.end)
          : translateSpan(def.timing, newT - eff.start, eff.start, eff.end),
      });
    }
  } else if (ev.kind === "peer-left") {
    if (intent.kind !== "translate") {
      ctx.emitError(validationError(
        `Only translate is supported on peer-left.`,
        "Resize the peer from the left edge of its peer-joined event.",
      ));
      return;
    }
    const newT = intent.newT;
    moves.push({ ev, newT });
    const def = ctx.doc.entities?.peers?.[ev.peerId];
    if (def?.timing) {
      const eff = peerEffective(ctx.doc, ev.peerId);
      patches.push({
        kind: "peer-timing",
        peerId: ev.peerId,
        span: setSpanEndAt(eff.start, newT),
      });
    }
  } else if (ev.kind === "session-opened") {
    if (intent.kind === "resize-end") {
      ctx.emitError(validationError(
        "Right-edge resize on session-opened is not supported.",
        "Drag the session-closed event instead — it is the right edge.",
      ));
      return;
    }
    const newT = intent.newT;
    const dt = newT - ev.t;
    moves.push({ ev, newT });
    if (intent.kind === "translate") {
      // The whole session moves: its close and every moment on its
      // trajectory keep their spacing from the open. An endpoint
      // attribution needs no keyframe patch beside the move — the
      // projection re-derives that track from these observations on
      // the next run — while the state track is authored on the
      // definition and has to be moved there too.
      for (const e of events) {
        if (e === ev) continue;
        if (
          (e.kind === "session-closed" ||
            e.kind === "session-state-changed" ||
            e.kind === "session-endpoint-attributed") &&
          e.sessionId === ev.sessionId
        ) {
          const slidT = e.t + dt;
          moves.push({ ev: e, newT: slidT });
          if (e.kind === "session-state-changed") {
            patches.push({
              kind: "session-keyframe-move",
              sessionId: e.sessionId,
              oldT: e.t,
              newT: slidT,
            });
          }
        }
      }
    }
    const def = ctx.doc.entities?.sessions?.[ev.sessionId];
    if (def?.timing) {
      const eff = sessionEffective(ctx.doc, ev.sessionId);
      // Painted-start dt for the span patch; see the message branch.
      patches.push({
        kind: "session-timing",
        sessionId: ev.sessionId,
        span: intent.kind === "resize-start"
          ? setSpanStartAt(def.timing, newT, eff.end)
          : translateSpan(def.timing, newT - eff.start, eff.start, eff.end),
      });
    }
  } else if (ev.kind === "session-closed") {
    if (intent.kind !== "translate") {
      ctx.emitError(validationError(
        `Only translate is supported on session-closed.`,
        "Resize the session from the left edge of its session-opened event.",
      ));
      return;
    }
    const newT = intent.newT;
    moves.push({ ev, newT });
    const def = ctx.doc.entities?.sessions?.[ev.sessionId];
    if (def?.timing) {
      const eff = sessionEffective(ctx.doc, ev.sessionId);
      patches.push({
        kind: "session-timing",
        sessionId: ev.sessionId,
        span: setSpanEndAt(eff.start, newT),
      });
    }
  } else if (ev.kind === "session-state-changed") {
    if (intent.kind !== "translate") {
      ctx.emitError(validationError(
        `Only translate is supported on session-state-changed.`,
        "Edge resizes apply to span boundaries, not interior keyframes.",
      ));
      return;
    }
    const newT = intent.newT;
    if (occupiedMoment(ctx, ev, newT)) return;
    moves.push({ ev, newT });
    patches.push({
      kind: "session-keyframe-move",
      sessionId: ev.sessionId,
      oldT: ev.t,
      newT,
    });
  } else {
    if (intent.kind !== "translate") {
      ctx.emitError(validationError(
        `Only translate is supported on ${ev.kind}.`,
        "Edge resizes apply to peer / session / message events only.",
      ));
      return;
    }
    if (occupiedMoment(ctx, ev, intent.newT)) return;
    moves.push({ ev, newT: intent.newT });
  }

  commitMoves(ctx, events, moves, patches);
}

/** Whether moving `ev` to `newT` would land it where the same session
 *  property already states something — and if so, says so.
 *
 *  A keyframe track holds one value per instant, so two moments of one
 *  property at one `t` is not a state the document can carry: the write
 *  REPLACES, and the moment that was standing there is gone. Dragged
 *  down to its own predecessor's time, a row therefore used to delete
 *  that predecessor and silently take its place — the track lost an
 *  entry, and the numbered list under the reader's pointer renumbered
 *  around a row that no longer existed.
 *
 *  Refusing is right rather than merging, because the two readings of
 *  "these two moments are now at the same instant" are "I meant to
 *  overwrite that one" and "I dragged too far", and only the reader
 *  knows which. The one that loses data is not the one to guess.
 *  Another property's moment at that instant is not a collision at all:
 *  the tracks are read separately and neither shadows the other. */
function occupiedMoment(
  ctx: AuthoringContext,
  ev: TimelineEvent,
  newT: number,
): boolean {
  if (newT === ev.t) return false;
  const moment = sessionMomentOf(ev);
  if (moment === null) return false;
  const spec = SESSION_TRAJECTORY[moment.property];
  const clash = primaryObservations(ctx.doc).find((other) =>
    other.id !== ev.id && other.t === newT &&
    spec.read(other, moment.sessionId) !== null
  );
  if (clash === undefined) return false;
  ctx.emitError(validationError(
    `The session already states its ${spec.noun} at ${newT}.`,
    `Drop this one somewhere else, or clear the ${spec.noun} already there.`,
  ));
  return true;
}

/** The shared back half of every span/event move: validate ordering
 *  against the pre-move state, apply the observation mutations,
 *  re-sort, grow the doc, apply the entity-doc patches, and refresh
 *  the render caches. Both the event-addressed `moveEvent` and the
 *  entity-addressed `moveEntitySpan` end here, so the two ways of
 *  naming a gesture cannot drift in what a committed move does.
 */
function commitMoves(
  ctx: AuthoringContext,
  events: TimelineEvent[],
  moves: Array<
    & { ev: TimelineEvent; newT: number }
    & ({ newArrivalT?: number } | Record<string, never>)
  >,
  patches: MovePatch[],
): void {
  // Where the plan puts every event it touches. Ordering is checked
  // against the finished gesture, not against the half of it that
  // has not been written yet — otherwise a peer or session dragged
  // earlier is refused by its own trailing events.
  const planned = new Map(moves.map((m) => [m.ev.id, m.newT]));
  for (const m of moves) {
    if (m.newT < 0) {
      ctx.emitError(validationError(
        `Event time (${m.newT}) is before the timeline start.`,
        "Drop the event at t ≥ 0.",
      ));
      return;
    }
    const orderErr = checkMoveOrdering(m.ev, m.newT, events, planned);
    if (orderErr) {
      ctx.emitError(orderErr);
      return;
    }
    if (m.ev.kind === "message-delivered") {
      const deliveredErr = checkDeliveredOrdering(
        events,
        m.ev.id,
        m.newT,
        planned,
      );
      if (deliveredErr) {
        ctx.emitError(deliveredErr);
        return;
      }
    }
  }

  // Apply observation mutations. Patches were already built from the
  // pre-move state, so we don't need to capture anything here.
  for (const m of moves) {
    m.ev.t = m.newT;
    if (m.ev.kind === "message-sent" && m.newArrivalT !== undefined) {
      m.ev.arrivalT = m.newArrivalT;
    }
  }
  events.sort((a, b) => a.t - b.t);
  for (const m of moves) growDurationToFit(ctx, m.ev);

  // Apply every entity-doc patch built alongside the moves. The
  // lane-bundle resolver reads `entity.timing`; segment colors and
  // the Inspector trajectory list read `entity.keyframes.state`.
  // Without these writes an observation move paints nothing new.
  for (const patch of patches) applyPatch(ctx, patch);

  // Swap doc.entities reference so the Scrubber's lane-bundle
  // WeakMap cache (keyed by entities identity) invalidates and
  // segment colors / spans repaint.
  bumpEntities(ctx);
  ctx.recomputeLayout();
  ctx.seekTo(ctx.clock.t);
}

/** Retime a peer or session span by naming the entity (see
 *  `MoveSpanIntent`). Anchored on the effective range — the same
 *  source of truth the timeline paints — so the gesture means "the
 *  edge you can see moves to `newT`". Observation events that exist
 *  for the entity move to agree; an entity with no observations yet
 *  (freshly authored) retimes through `entity.timing` alone.
 */
export function moveEntitySpan(
  ctx: AuthoringContext,
  intent: MoveSpanIntent,
): void {
  const { ref, newT } = intent;
  const events = primaryObservations(ctx.doc);
  type Move =
    & { ev: TimelineEvent; newT: number }
    & ({ newArrivalT?: number } | Record<string, never>);
  const moves: Move[] = [];
  const patches: MovePatch[] = [];
  if (newT < 0) {
    ctx.emitError(validationError(
      `Event time (${newT}) is before the timeline start.`,
      "Drop the edge at t \u2265 0.",
    ));
    return;
  }

  if (ref.kind === "peer") {
    const def = ctx.doc.entities?.peers?.[ref.id];
    if (!def) {
      ctx.emitError(notFoundError("peer", ref.id));
      return;
    }
    const timing = def.timing ?? {
      start: implicitBound(0),
      duration: implicitBound(0),
    };
    const eff = peerEffective(ctx.doc, ref.id);
    const joined = events.find(
      (e) => e.kind === "peer-joined" && e.peerId === ref.id,
    );
    const left = events.find(
      (e) => e.kind === "peer-left" && e.peerId === ref.id,
    );
    if (intent.kind === "resize-start") {
      if (Number.isFinite(eff.end) && newT > eff.end) {
        ctx.emitError(validationError(
          `Peer start (${newT}) is after its end (${eff.end}).`,
          "Move the start handle before the end.",
        ));
        return;
      }
      if (joined) moves.push({ ev: joined, newT });
      patches.push({
        kind: "peer-timing",
        peerId: ref.id,
        span: setSpanStartAt(timing, newT, eff.end),
      });
    } else if (intent.kind === "resize-end") {
      if (newT < eff.start) {
        ctx.emitError(validationError(
          `Peer end (${newT}) is before its start (${eff.start}).`,
          "Move the end handle after the start.",
        ));
        return;
      }
      if (left) moves.push({ ev: left, newT });
      patches.push({
        kind: "peer-timing",
        peerId: ref.id,
        span: setSpanEndAt(eff.start, newT),
      });
    } else {
      const dt = newT - eff.start;
      if (joined) moves.push({ ev: joined, newT });
      if (left && Number.isFinite(eff.end)) {
        moves.push({ ev: left, newT: eff.end + dt });
      }
      patches.push({
        kind: "peer-timing",
        peerId: ref.id,
        span: translateSpan(timing, dt, eff.start, eff.end),
      });
    }
  } else {
    const def = ctx.doc.entities?.sessions?.[ref.id];
    if (!def) {
      ctx.emitError(notFoundError("session", ref.id));
      return;
    }
    const timing = def.timing ?? {
      start: implicitBound(0),
      duration: implicitBound(0),
    };
    const eff = sessionEffective(ctx.doc, ref.id);
    const opened = events.find(
      (e) => e.kind === "session-opened" && e.sessionId === ref.id,
    );
    const closed = events.find(
      (e) => e.kind === "session-closed" && e.sessionId === ref.id,
    );
    if (intent.kind === "resize-start") {
      if (Number.isFinite(eff.end) && newT > eff.end) {
        ctx.emitError(validationError(
          `Session start (${newT}) is after its end (${eff.end}).`,
          "Move the start handle before the end.",
        ));
        return;
      }
      if (opened) moves.push({ ev: opened, newT });
      patches.push({
        kind: "session-timing",
        sessionId: ref.id,
        span: setSpanStartAt(timing, newT, eff.end),
      });
    } else if (intent.kind === "resize-end") {
      if (newT < eff.start) {
        ctx.emitError(validationError(
          `Session end (${newT}) is before its start (${eff.start}).`,
          "Move the end handle after the start.",
        ));
        return;
      }
      if (closed) moves.push({ ev: closed, newT });
      patches.push({
        kind: "session-timing",
        sessionId: ref.id,
        span: setSpanEndAt(eff.start, newT),
      });
    } else {
      const dt = newT - eff.start;
      if (opened) moves.push({ ev: opened, newT });
      for (const e of events) {
        if (e.kind === "session-closed" && e.sessionId === ref.id) {
          moves.push({ ev: e, newT: e.t + dt });
        }
        // Every moment on the session's trajectory rides along; see
        // the same slide in `moveEvent` for why only the state track
        // needs a patch beside the move.
        if (
          e.kind === "session-endpoint-attributed" && e.sessionId === ref.id
        ) {
          moves.push({ ev: e, newT: e.t + dt });
        }
        if (e.kind === "session-state-changed" && e.sessionId === ref.id) {
          const slidT = e.t + dt;
          moves.push({ ev: e, newT: slidT });
          patches.push({
            kind: "session-keyframe-move",
            sessionId: ref.id,
            oldT: e.t,
            newT: slidT,
          });
        }
      }
      patches.push({
        kind: "session-timing",
        sessionId: ref.id,
        span: translateSpan(timing, dt, eff.start, eff.end),
      });
    }
  }

  commitMoves(ctx, events, moves, patches);
}

/** Swap `doc.entities` for a shallow copy so downstream WeakMap
 *  caches keyed by its reference (e.g. the Scrubber lane-bundle
 *  cache) invalidate after in-place authoring mutations. */
export function bumpEntities(ctx: AuthoringContext): void {
  if (ctx.doc.entities !== undefined) {
    ctx.doc.entities = { ...ctx.doc.entities };
  }
}
