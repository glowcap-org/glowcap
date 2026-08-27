/**
 * TimeSpan — `(start, duration)` storage for every temporal entity
 * (peer, session, message). End is derived as `start + duration` and
 * is NEVER stored. This is the only authoritative shape; all other
 * representations (engine, scrubber, inspector) read through the
 * resolvers in sibling modules.
 *
 * # Three layers
 *
 * Every entity has three coexisting views of its placement, in
 * strictly increasing constraint:
 *
 *   1. **stored**     — this module. Per-axis Bound = (value, explicit).
 *                       What undo records, what serializes.
 *   2. **intrinsic**  — `inheritance.ts`. Layer 1 with implicit axes
 *                       filled in from the parent's intrinsic. "What
 *                       this entity wants."
 *   3. **effective**  — `effective.ts`. Layer 2 clamped by the
 *                       parent's effective context. "What the system
 *                       actually paints."
 *
 * Layer 1 is the only one in the doc. Layers 2 and 3 are pure
 * derivations. Constraints never write back; the user's intent is
 * preserved even when a parent boundary hides it.
 *
 * # Parent chain
 *
 *   peer     → world (unbounded)
 *   session  → peerA.effective ∩ peerB.effective
 *   message  → session.effective
 *
 * Walked by `doc-resolver.ts`. New entity kinds add a rule there.
 *
 * # Invariants enforced here
 *
 *   - duration.value >= 0 always (clamped on set)
 *   - zero-duration is legal (point-in-time entity)
 *   - end is never stored. Gestures pick their own end-semantics at
 *     the intent layer (rigid move keeps duration, right-resize keeps
 *     start, etc); see `authoring/moves.ts` and the gesture-shaped
 *     rewrites at the bottom of this module.
 *
 * # Gesture rewrites (`translateSpan` / `setSpanEndAt` /
 *   `setSpanStartAt`)
 *
 * All take *resolved* (effective) bounds, not raw `span.start.value`,
 * and write both axes explicit. Reason: a positive user gesture pins
 * both ends ("this span lives here, with this duration"). Leaving an
 * axis implicit lets `intrinsicOf` fall back to parent-inheritance,
 * which during a drag manifests as the pill silently resizing —
 * the original bug these helpers were carved out to fix.
 *
 * # Design rationale
 *
 * The design rationale (why three layers, not two; why split intent
 * from constraint; why storage is `(start, duration)`) lives in
 * `docs/temporal-model.md`. That file is reference, not spec. The
 * spec is this module and its siblings.
 */

import { type Bound, withValue } from "./bound.ts";

export type TimeSpan = {
	start: Bound;
	duration: Bound;
	/** Provenance: `true` when the projection derived this span from
	 *  observations (`projectFromObservations`), absent when a user
	 *  authored it. Derived spans are re-derived whenever the entity's
	 *  observations grow (a live feed's late-arriving `peer-left` /
	 *  `session-closed` must land); authored spans are never touched
	 *  by projection. Every authoring op in this module strips the
	 *  flag, so an edit — even one that re-states the derived value —
	 *  promotes the span to authored. (`| undefined` matches the zod
	 *  schema's `.optional()` inference under
	 *  `exactOptionalPropertyTypes`.) */
	derived?: true | undefined;
};

/** Mark a span as projection-derived. Only `projectFromObservations`
 *  calls this; see `TimeSpan.derived`. */
export const markDerived = (v: TimeSpan): TimeSpan => ({
	start: v.start,
	duration: v.duration,
	derived: true,
});

/** Strip the derived marker: the span is now user intent. Applied by
 *  every authoring op below, and by any write path that assigns a
 *  span it did not build itself (`applyPatch`). */
export const asAuthored = (v: TimeSpan): TimeSpan =>
	v.derived === undefined ? v : { start: v.start, duration: v.duration };

/** True when the span is projection-owned (see `TimeSpan.derived`).
 *  No-op guards consult this: re-stating a derived value IS a real
 *  change, because it changes the span's authority, not its value —
 *  the same rule as pinning a peer at its current layout position. */
export const isDerived = (v: TimeSpan): boolean => v.derived === true;

/* ------------------------------------------------------------------ *
 * Authoring ops — return a new TimeSpan. Do NOT consult context;
 * that's the resolver's job. Engine wiring lives in `authoring/*.ts`.
 * ------------------------------------------------------------------ */

export function setStart(v: TimeSpan, value: number): TimeSpan {
	return { start: withValue(v.start, value), duration: v.duration };
}

export function clearStart(v: TimeSpan): TimeSpan {
	return {
		start: { ...v.start, explicit: false },
		duration: v.duration,
	};
}

export function setDuration(v: TimeSpan, value: number): TimeSpan {
	return {
		start: v.start,
		duration: withValue(v.duration, Math.max(0, value)),
	};
}

export function clearDuration(v: TimeSpan): TimeSpan {
	return {
		start: v.start,
		duration: { ...v.duration, explicit: false },
	};
}

/** Sugar — set end by computing duration from the entity's
 *  currently-resolved intrinsic start. Caller MUST pass that
 *  resolved start (this module can't ask context). */
export function setEnd(
	v: TimeSpan,
	endValue: number,
	intrinsicStart: number,
): TimeSpan {
	return setDuration(v, endValue - intrinsicStart);
}

export function clearEnd(v: TimeSpan): TimeSpan {
	return clearDuration(v);
}

/** Rigid move — change start, leave duration untouched. Caller
 *  passes the resolved start to compute the new start absolutely. */
export function moveBy(
	v: TimeSpan,
	delta: number,
	intrinsicStart: number,
): TimeSpan {
	return setStart(v, intrinsicStart + delta);
}

/** Alias for setDuration with intent-naming. */
export const resize = setDuration;

/* ------------------------------------------------------------------ *
 * Gesture-shaped span rewrites — used by move-event to translate the
 * user's drag intent into an entity.timing patch. These take the
 * pre-move *resolved* (effective) bounds rather than the raw span
 * values, because resolved bounds reflect what the renderer actually
 * paints (parent-inheritance filled in). Writing back from raw
 * `span.start.value=0` would visually no-op when start was implicit.
 * ------------------------------------------------------------------ */

/** Body-translate: shift `span` by `dt`. Both bounds become explicit
 *  because the gesture pins start AND end ("this span lives here,
 *  with this duration"). Leaving either implicit lets `intrinsicOf`
 *  fall back to parent-inheritance, which manifests as the pill
 *  appearing to resize during a drag — the original bug this helper
 *  was carved out to fix.
 *
 *  Open span (no finite resolved end): duration stays as-is. There
 *  is no user-stated end to pin against; the pill keeps trailing to
 *  doc.duration which is the only sensible visual. */
export function translateSpan(
	span: TimeSpan,
	dt: number,
	resolvedStart: number,
	resolvedEnd: number,
): TimeSpan {
	const newStart = resolvedStart + dt;
	if (Number.isFinite(resolvedEnd)) {
		return {
			start: { value: newStart, explicit: true },
			duration: {
				value: Math.max(0, resolvedEnd - resolvedStart),
				explicit: true,
			},
		};
	}
	return {
		start: { value: newStart, explicit: true },
		duration: span.duration,
	};
}

/** Right-edge resize: pin end to `newEndT`, keep the resolved start.
 *  Both bounds explicit so duration recomputes from the new end
 *  rather than inheriting from the parent intrinsic. */
export function setSpanEndAt(
	resolvedStart: number,
	newEndT: number,
): TimeSpan {
	return {
		start: { value: resolvedStart, explicit: true },
		duration: {
			value: Math.max(0, newEndT - resolvedStart),
			explicit: true,
		},
	};
}

/** Left-edge resize: pin start to `newStartT`, keep the resolved end.
 *  Counterpart of `setSpanEndAt`; same explicit-both reasoning.
 *
 *  Open span (no finite resolved end): duration stays as-is.
 *  Mirrors `translateSpan`'s open-span branch — the user did not
 *  state an end, so pinning duration explicitly would convert an
 *  open pill into one with `duration = Infinity`, which then paints
 *  past the doc and confuses every downstream resolver. */
export function setSpanStartAt(
	span: TimeSpan,
	newStartT: number,
	resolvedEnd: number,
): TimeSpan {
	if (!Number.isFinite(resolvedEnd)) {
		return {
			start: { value: newStartT, explicit: true },
			duration: span.duration,
		};
	}
	return {
		start: { value: newStartT, explicit: true },
		duration: {
			value: Math.max(0, resolvedEnd - newStartT),
			explicit: true,
		},
	};
}
