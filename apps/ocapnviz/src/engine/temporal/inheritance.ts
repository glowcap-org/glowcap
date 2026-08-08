/**
 * Inheritance resolver — turns a TimeSpan + its parent's
 * intrinsic range into the entity's own intrinsic range. Pure;
 * does NOT apply context constraints (effective.ts does that).
 *
 * Layer 2 of the three-layer model. See
 * `docs/temporal-model.md`.
 *
 * Resolution rules per axis:
 *   - explicit start → use stored value
 *   - implicit start → inherit parent's intrinsic.start
 *   - explicit duration → end = start + stored duration
 *   - implicit duration → end = parent's intrinsic.end
 *     ("fill remaining context")
 *
 * "Inherit parent's intrinsic, not effective" is deliberate. When
 * a session's effective is clamped by peer overlap, an implicit
 * message-duration still tracks the session's pre-clamp end so
 * the message reads as "wanting" what the session "wants." The
 * message's own effective layer then re-clamps under the same
 * constraints; the result for rendering is identical, but the
 * intent through the chain is preserved for the Inspector to
 * surface "clamped by session" instead of silently shrinking.
 */

import type { TimeSpan } from "./time-span.ts";
import type { EffectiveRange } from "./range.ts";

export function intrinsicOf(
  span: TimeSpan,
  parentIntrinsic: EffectiveRange,
): EffectiveRange {
  const start = span.start.explicit ? span.start.value : parentIntrinsic.start;
  const end = span.duration.explicit
    ? start + span.duration.value
    : parentIntrinsic.end;
  return { start, end };
}
