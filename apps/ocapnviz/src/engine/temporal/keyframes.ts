/**
 * Keyframes, per-property piecewise-constant value over time.
 *
 * A keyframe is `(t, value)`. A keyframe **track** is a list of
 * keyframes sorted by `t`. Reading `keyframeAt(track, t)` returns
 * the value of the most recent keyframe with `keyframe.t <= t`
 * (half-open `[start, end)` semantics, the keyframe takes effect
 * AT `t`, not the instant after).
 *
 * Used for entity properties that change value during the entity's
 * span. The canonical first case is `session.state`:
 *   keyframes.state = [
 *     (0,  "negotiating"),
 *     (10, "open"),
 *     (15, "draining"),
 *   ]
 * At t=10 exactly, state is "open", the new keyframe just kicked
 * in. At t=14.999, still "open". At t=15, "draining".
 *
 * See `docs/data-model.md` for the larger architecture.
 */

import { z } from "zod";

/** Generic factory, call with the value schema, get back a
 *  Keyframe<T> schema. e.g. `Keyframe(SessionState)`. */
export function Keyframe<TValue extends z.ZodTypeAny>(
	value: TValue,
) {
	return z.object({
		/** Simulated time at which this keyframe's value takes effect. */
		t: z.number().finite(),
		value,
	});
}

export type Keyframe<T> = {
	t: number;
	value: T;
};

export type KeyframeTrack<T> = readonly Keyframe<T>[];

/** Look up the active value at time `t`. Half-open `[start, end)`:
 *  if `keyframe.t === t`, that keyframe is in effect at `t`.
 *
 *  Returns `undefined` when the track is empty OR `t` is before
 *  the first keyframe, callers fall back to a default (e.g.
 *  entity.identity.initialState).
 *
 *  Linear scan. Tracks are expected to be tiny (single digits per
 *  property per entity). Bump to binary search if a real workload
 *  ever needs it. */
export function keyframeAt<T>(
	track: KeyframeTrack<T> | undefined,
	t: number,
): T | undefined {
	if (!track || track.length === 0) return undefined;
	let active: Keyframe<T> | undefined;
	for (const kf of track) {
		if (kf.t > t) break;
		active = kf;
	}
	return active?.value;
}

/** The keyframe the track DECLARES at exactly `t`, or undefined when
 *  it declares none there.
 *
 *  The sibling of `keyframeAt`, and the distinction between them is
 *  the whole of what a track is. `keyframeAt` answers what the
 *  property IS at `t`, which a keyframe at some earlier time can
 *  answer. This answers what the document SAYS at `t`, which only a
 *  keyframe standing there can.
 *
 *  A reader painting the stage wants the first. A writer asking
 *  "would this change the document" wants the second. Declaring a
 *  value at a time nothing declared it pins it there: edits to the
 *  genesis value, and to earlier keyframes, stop reaching past it. So
 *  such a write is a real change even when the value in effect was
 *  already that, and `no-op-guards.ts` states that rule once for
 *  every trajectory write. */
export function keyframeExactlyAt<T>(
	track: KeyframeTrack<T> | undefined,
	t: number,
): Keyframe<T> | undefined {
	return track?.find((kf) => kf.t === t);
}

/** Insert / replace a keyframe at `t`. Returns a new sorted track.
 *  If a keyframe already exists at exactly `t`, its value is
 *  replaced (last write wins). */
export function setKeyframe<T>(
	track: KeyframeTrack<T> | undefined,
	t: number,
	value: T,
): KeyframeTrack<T> {
	const out: Keyframe<T>[] = [];
	let inserted = false;
	for (const kf of track ?? []) {
		if (kf.t === t) {
			out.push({ t, value });
			inserted = true;
		} else if (!inserted && kf.t > t) {
			out.push({ t, value });
			out.push(kf);
			inserted = true;
		} else {
			out.push(kf);
		}
	}
	if (!inserted) out.push({ t, value });
	return out;
}

/** Remove the keyframe at exactly `t`. No-op when none matches. */
export function removeKeyframe<T>(
	track: KeyframeTrack<T> | undefined,
	t: number,
): KeyframeTrack<T> {
	if (!track) return [];
	return track.filter((kf) => kf.t !== t);
}
