/**
 * World — the gospel root context for all temporal inheritance.
 * Starts at 0; runs to infinity. It is not user-editable: the
 * resolvers read it through this one module, so a change to that
 * boundary lands here and nowhere else.
 *
 * See `docs/temporal-model.md`.
 */

import type { EffectiveRange } from "./range.ts";

export const WORLD_RANGE: EffectiveRange = {
	start: 0,
	end: Number.POSITIVE_INFINITY,
};

/** Intrinsic and effective are equal at the root — world has no
 *  parent, no inheritance, no constraints. Exported as a pair for
 *  the resolver's "the entity above me at the top" base case. */
export const WORLD_INTRINSIC: EffectiveRange = WORLD_RANGE;
export const WORLD_EFFECTIVE: EffectiveRange = WORLD_RANGE;
