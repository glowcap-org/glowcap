/**
 * Bound — one side of a time span (a start or a duration).
 *
 * A bound holds both a stored value and an `explicit` flag. When
 * `explicit` is false, the side inherits from its context at read
 * time and the stored `value` is retained for redo / toggle-back.
 *
 * See `docs/temporal-model.md` for the model this
 * lives inside (stored / intrinsic / effective layers, time-span
 * storage).
 */

export type Bound = {
	/** User-stored value. Used iff `explicit` is true. Preserved when
	 *  implicit so flipping back doesn't lose the user's last input. */
	value: number;
	/** When false, this side inherits from context at read time. */
	explicit: boolean;
};

export const implicitBound = (value: number = 0): Bound => ({
	value,
	explicit: false,
});

export const explicitBound = (value: number): Bound => ({
	value,
	explicit: true,
});

/** Make a bound explicit while preserving its stored value. If the
 *  caller wants the post-flip value to match what was being
 *  inherited, they should snapshot the inherited value into `value`
 *  themselves before calling — `withExplicit` does not consult
 *  context (it can't; it doesn't know about it). */
export const withExplicit = (b: Bound): Bound => b.explicit ? b : { ...b, explicit: true };

/** Set the stored value AND mark explicit. The common case for an
 *  authoring intent that takes a user-typed number. */
export const withValue = (_b: Bound, value: number): Bound => ({
	value,
	explicit: true,
});
