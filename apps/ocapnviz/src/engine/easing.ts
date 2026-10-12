/**
 * Easing curves, pure mappings `[0, 1] → [0, 1]` that shape interpolation
 * progress. Pure functions: substituting one for another preserves
 * determinism (same input `t` → same output position).
 */

export type EasingFn = (t: number) => number;

/** Cubic Hermite smoothstep (`3t² − 2t³`). Symmetric ease-in-out. */
export const smoothstep: EasingFn = (t) => {
	const x = t < 0 ? 0 : t > 1 ? 1 : t;
	return x * x * (3 - 2 * x);
};
