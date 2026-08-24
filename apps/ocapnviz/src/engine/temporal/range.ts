/**
 * EffectiveRange — a resolved temporal range with concrete start
 * and end. The output of inheritance and effective resolution; the
 * primitive every reader (Stage, Scrubber, Inspector indicator)
 * consumes.
 *
 * NOT the same as a TimeSpan. A TimeSpan is *storage* (per
 * axis: stored value + explicit flag). An EffectiveRange is
 * *derived* (concrete numeric start + end). Use TimeSpan for
 * authoring intents; use EffectiveRange for rendering and reads.
 *
 * See `docs/temporal-model.md`.
 */

export type EffectiveRange = {
	start: number;
	end: number;
};

export const rangeOf = (start: number, end: number): EffectiveRange => ({
	start,
	end,
});

/** Duration of a range. Always non-negative — clamps to 0 for the
 *  degenerate `start > end` case. */
export const durationOf = (r: EffectiveRange): number => Math.max(0, r.end - r.start);

/** A range is empty when its end is at or before its start.
 *  Drives the ghost-render gate on the Stage and the "hidden"
 *  state for sessions whose peers don't overlap. */
export const isEmpty = (r: EffectiveRange): boolean => r.end <= r.start;

export const containsTime = (r: EffectiveRange, t: number): boolean => t >= r.start && t < r.end;

/** Intersect two ranges. For a session with two peer parents,
 *  call `intersect(peerA.effective, peerB.effective)` to produce
 *  the session's context. The result may be empty if the inputs
 *  don't overlap — `isEmpty` catches that. */
export const intersect = (
	a: EffectiveRange,
	b: EffectiveRange,
): EffectiveRange => ({
	start: Math.max(a.start, b.start),
	end: Math.min(a.end, b.end),
});

/** Clamp one range to fit inside another. The "context clamp"
 *  used in effective resolution. SATURATING: both endpoints are
 *  pulled into the outer bounds independently, so the result is
 *  always a valid (start ≤ end, possibly zero-duration) range
 *  somewhere inside outer — even when inner is entirely disjoint.
 *  Disjoint inputs collapse to a zero-duration stamp at the
 *  nearest outer endpoint, which keeps the entity visible and
 *  clickable at the boundary of its parent context. Paired with
 *  `clampReasonFor`, the Inspector explains the collapse and the
 *  user can recover by editing the stored intent. */
export const clampInto = (
	inner: EffectiveRange,
	outer: EffectiveRange,
): EffectiveRange => {
	const lo = outer.start;
	const hi = outer.end;
	const clamp = (t: number) => t < lo ? lo : t > hi ? hi : t;
	return { start: clamp(inner.start), end: clamp(inner.end) };
};
