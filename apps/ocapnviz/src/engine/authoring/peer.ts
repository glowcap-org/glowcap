/**
 * Peer-level authoring operations. Each function takes the
 * `AuthoringContext` as its first argument so it has access to the
 * doc, world, clock, layout, id-minter, and post-mutation seek
 * callback. No engine internals beyond the context.
 *
 * `repositionPeer` stays on the Engine because it's a hot-path
 * special-case (called continuously during builder drags) that
 * refreshes playback's stage at the playhead the same frame.
 * The document pin itself lives in `placement.ts`. Every other peer
 * mutation lives here.
 */

import type { PeerProfile } from "../../schema/topology.ts";
import { patchPeerDefinition } from "../entities.ts";
import { cascadeDelete } from "../schema/cascade.ts";
import { restoreSnapshotInto, takeSnapshot } from "../snapshot.ts";
import { implicitBound } from "../temporal/bound.ts";
import { peerEffective } from "../temporal/doc-resolver.ts";
import { clearDuration, clearStart, setDuration, setStart } from "../temporal/time-span.ts";
import { observationsOf } from "../temporal/recording-access.ts";
import type { TimelineEvent } from "../timeline.ts";
import { notFoundError, validationError } from "../errors.ts";
import type { AuthoringContext } from "./context.ts";
import { commitEntityAuthoring, removeObservations, upsertObservation } from "./events.ts";
import { PEER_TRAJECTORY, type PeerProperty, type PeerUpdate, peerUpdateStates } from "../trajectory.ts";

function defaultPeerTiming() {
  return { start: implicitBound(0), duration: implicitBound(0) };
}

// Each sync helper writes through a `time-span.ts` authoring op —
// the one vocabulary that produces authored spans (a derived span
// loses its marker here, so projection stops re-deriving it).

function syncPeerDuration(
  ctx: AuthoringContext,
  peerId: string,
  duration: number,
): void {
  const def = ctx.doc.entities?.peers?.[peerId];
  if (!def) return;
  def.timing = setDuration(def.timing ?? defaultPeerTiming(), duration);
}

function syncPeerEndCleared(ctx: AuthoringContext, peerId: string): void {
  const def = ctx.doc.entities?.peers?.[peerId];
  if (!def) return;
  def.timing = clearDuration(def.timing ?? defaultPeerTiming());
}

function syncPeerStart(
  ctx: AuthoringContext,
  peerId: string,
  startT: number,
): void {
  const def = ctx.doc.entities?.peers?.[peerId];
  if (!def) return;
  def.timing = setStart(def.timing ?? defaultPeerTiming(), startT);
}

function syncPeerStartCleared(ctx: AuthoringContext, peerId: string): void {
  const def = ctx.doc.entities?.peers?.[peerId];
  if (!def) return;
  def.timing = clearStart(def.timing ?? defaultPeerTiming());
}

/** Patch peer-level fields. `peerId` (key) and `position`
 * (`repositionPeer`'s own entry point) are excluded.
 *
 * Commits like any other entity edit, because both fields this can write are
 * read by the layout: the name decides how wide a box the solver keeps for
 * this peer (`nodeFootprints` in `node-footprint.ts`), and the durable name
 * decides which session ends are claims about it (`engine/claims.ts`).
 * Re-seeking alone left the layout answering from the peer's old identity, so
 * an end that had just become a claim was drawn as one while still standing
 * where an ordinary body had been solved. */
export function updatePeer(
  ctx: AuthoringContext,
  peerId: string,
  patch: {
    label?: string;
    profile?: PeerProfile;
    designator?: string;
  },
): void {
  // Identity write to the entities map first — this is what readers
  // (Sidebar, peerInfo helper) consult. Works for eternal-start peers
  // too (no peer-joined event to mutate).
  patchPeerDefinition(ctx.doc, peerId, patch);
  // Mirror to the peer-joined payload (if present) so the wire format
  // stays consistent. This is the name the peer JOINS under — a
  // session's `initialState` in peer form. Later renames are their
  // own moments (`setPeerRename`) and this does not touch them, the
  // same way editing a session's initial state leaves its state
  // keyframes alone. No-op for eternal-start peers.
  for (const ev of observationsOf(ctx.doc) as TimelineEvent[]) {
    if (ev.kind !== "peer-joined" || ev.peerId !== peerId) continue;
    if (patch.label !== undefined) ev.label = patch.label;
    if (patch.profile !== undefined) ev.profile = patch.profile;
    if (patch.designator !== undefined) {
      if (patch.designator === "") {
        delete (ev as { designator?: string }).designator;
      } else {
        ev.designator = patch.designator;
      }
    }
  }
  commitEntityAuthoring(ctx);
}

/** The peer's own update observation at exactly `t` — the moment a
 *  write lands on and a clear reads from. One observation carries
 *  every property the peer restated at that instant. */
const peerUpdateAt = (peerId: string, t: number) => (ev: TimelineEvent): boolean =>
  ev.kind === "peer-updated" && ev.peerId === peerId && ev.t === t;

function updateAt(
  ctx: AuthoringContext,
  peerId: string,
  t: number,
): PeerUpdate | undefined {
  for (const ev of observationsOf(ctx.doc) as readonly TimelineEvent[]) {
    if (peerUpdateAt(peerId, t)(ev) && ev.kind === "peer-updated") return ev;
  }
  return undefined;
}

/** State `value` for one of the peer's temporal properties from `t`
 *  onward, replacing what it stated about that property at `t`. The
 *  peer's keyframe tracks derive from these observations on every
 *  projection run, so writing the observation IS the write — unlike
 *  a session's state track, there is no second copy on the
 *  definition to keep in step. The value the peer ARRIVES with is
 *  `updatePeer` (a session's `initialState` in peer form); this
 *  states a change after that.
 *
 *  Which properties exist, and how a value sits on the observation,
 *  live in `trajectory.ts` — this op learns neither. */
export function setPeerUpdate(
  ctx: AuthoringContext,
  peerId: string,
  t: number,
  property: PeerProperty,
  value: string,
): void {
  if (ctx.doc.entities?.peers?.[peerId] === undefined) {
    ctx.emitError(notFoundError("peer", peerId));
    return;
  }
  const start = peerEffective(ctx.doc, peerId).start;
  if (t < start) {
    const noun = PEER_TRAJECTORY[property].noun;
    ctx.emitError(validationError(
      `A new ${noun} at ${t} is before the peer arrives (${start}).`,
      "Drop the change inside the peer's lifetime, or move the peer's start earlier.",
    ));
    return;
  }
  const existing = updateAt(ctx, peerId, t);
  const base: PeerUpdate = existing ??
    { id: `auth-${ctx.mintId()}`, kind: "peer-updated", t, peerId };
  upsertObservation(
    ctx,
    peerUpdateAt(peerId, t),
    PEER_TRAJECTORY[property].write(base, value),
  );
  commitEntityAuthoring(ctx, t);
}

/** Stop stating one property at exactly `t`. The observation stays
 *  while it still states something else about that moment, and goes
 *  when it states nothing — an observation that changes nothing is
 *  not a moment (`momentOf`). No-op when nothing was stated. */
export function removePeerUpdate(
  ctx: AuthoringContext,
  peerId: string,
  t: number,
  property: PeerProperty,
): void {
  const existing = updateAt(ctx, peerId, t);
  if (existing === undefined) return;
  const spec = PEER_TRAJECTORY[property];
  if (spec.read(existing) === null) return;
  const cleared = spec.clear(existing);
  if (peerUpdateStates(cleared).length === 0) {
    removeObservations(ctx, peerUpdateAt(peerId, t));
  } else {
    upsertObservation(ctx, peerUpdateAt(peerId, t), cleared);
  }
  commitEntityAuthoring(ctx);
}

/** Remove a peer and everything that depends on it. Cascades through
 * the schema's reference graph (`engine/schema/edges.ts`): every
 * session referencing the peer, every message on those sessions,
 * every event referencing any of the above, and every doc-level
 * index containing any of the removed ids. One undo step. */
export function deletePeer(ctx: AuthoringContext, peerId: string): void {
  const next = cascadeDelete(ctx.doc, "peer", peerId);
  restoreSnapshotInto(ctx.doc, takeSnapshot(next));
  ctx.seekTo(ctx.clock.t);
}

/** Set the peer's duration. Mutates entity.timing.duration directly —
 *  this is the storage-shaped intent, matching the TimeSpan model. */
export function setPeerDuration(
  ctx: AuthoringContext,
  peerId: string,
  duration: number,
): void {
  const def = ctx.doc.entities?.peers?.[peerId];
  if (!def) {
    ctx.emitError(notFoundError("peer", peerId));
    return;
  }
  if (!(duration >= 0)) {
    ctx.emitError(validationError(
      `Peer duration must be ≥ 0 (got ${duration}).`,
      "Drag the duration handle forward, or type a non-negative value.",
    ));
    return;
  }
  syncPeerDuration(ctx, peerId, duration);
  commitEntityAuthoring(ctx, peerEffective(ctx.doc, peerId).end);
}

/** End-flavored wrapper around `setPeerDuration`. Translates absolute
 *  `t` to a duration off the peer's effective start. Prefer
 *  `setPeerDuration` for inspector-style edits that already know the
 *  duration; this stays for drag-to-arrival-time gestures. */
export function setPeerEnd(
  ctx: AuthoringContext,
  peerId: string,
  t: number,
): void {
  const def = ctx.doc.entities?.peers?.[peerId];
  if (!def) {
    ctx.emitError(notFoundError("peer", peerId));
    return;
  }
  const start = peerEffective(ctx.doc, peerId).start;
  if (t < start) {
    ctx.emitError(validationError(
      `Peer end (${t}) is before its start (${start}).`,
      "Move the end handle past the start, or clear the start first.",
    ));
    return;
  }
  setPeerDuration(ctx, peerId, t - start);
}

/** Restore the peer's implicit (eternal) end. */
export function clearPeerEnd(ctx: AuthoringContext, peerId: string): void {
  syncPeerEndCleared(ctx, peerId);
  commitEntityAuthoring(ctx);
}

/** Set the peer's start time. Mutates entity.timing.start to
 *  explicit(t). Validated against the peer's effective end. */
export function setPeerStart(
  ctx: AuthoringContext,
  peerId: string,
  t: number,
): void {
  const def = ctx.doc.entities?.peers?.[peerId];
  if (!def) {
    ctx.emitError(notFoundError("peer", peerId));
    return;
  }
  const effEnd = peerEffective(ctx.doc, peerId).end;
  if (Number.isFinite(effEnd) && t > effEnd) {
    ctx.emitError(validationError(
      `Peer start (${t}) is after its end (${effEnd}).`,
      "Move the start handle before the end, or clear the end first.",
    ));
    return;
  }
  syncPeerStart(ctx, peerId, t);
  commitEntityAuthoring(ctx, t);
}

/** Restore the peer to implicit-start (inherits from world = 0). */
export function clearPeerStart(
  ctx: AuthoringContext,
  peerId: string,
): void {
  syncPeerStartCleared(ctx, peerId);
  commitEntityAuthoring(ctx);
}
