/**
 * Effective resolver — takes an entity's intrinsic range and its
 * parent's effective range, returns the effective range. Pure.
 *
 * Layer 3 of the three-layer model. See
 * `docs/temporal-model.md`.
 *
 * The output is what Stage / Scrubber / hit-test / "is this
 * visible" checks all read. May be empty (`isEmpty(result) ===
 * true`) when constraints squeeze the intrinsic range out of the
 * context window entirely — that's the "hidden but selectable"
 * state for sessions whose peers don't overlap.
 *
 * Does NOT mutate the doc. Effective is a pure function of stored
 * + ancestor state, recomputed on every read.
 */

import { clampInto, type EffectiveRange } from "./range.ts";

export function effectiveOf(
  intrinsic: EffectiveRange,
  parentEffective: EffectiveRange,
): EffectiveRange {
  return clampInto(intrinsic, parentEffective);
}
