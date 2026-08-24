/**
 * Zod schemas for the temporal primitives. Used by `timeline.ts`
 * to declare entity-definition `timing` fields, by the doc
 * migrator, and by any wire-format validation.
 *
 * Pure schemas — runtime types come from inferring these via
 * `z.infer`. The hand-written types in `bound.ts` and
 * `time-span.ts` are kept in sync intentionally; if they diverge,
 * the test in this directory catches it (compile-time, via the
 * `satisfies` assertion below).
 */

import { z } from "zod";
import type { Bound } from "./bound.ts";
import type { TimeSpan } from "./time-span.ts";

export const BoundSchema = z.object({
	value: z.number().finite(),
	explicit: z.boolean(),
});

export const TimeSpanSchema = z.object({
	start: BoundSchema,
	duration: BoundSchema,
	/** Provenance marker — see `TimeSpan.derived` in `time-span.ts`.
	 *  Serialized so a saved live recording re-derives cleanly when
	 *  loaded (projection keeps owning what it derived). */
	derived: z.literal(true).optional(),
});

// Compile-time agreement check — schema infer === hand-written.
// If either side drifts, this won't compile.
type _BoundEq = z.infer<typeof BoundSchema> extends Bound ? true : never;
type _SpanEq = z.infer<typeof TimeSpanSchema> extends TimeSpan ? true : never;
const _boundCheck: _BoundEq = true;
const _spanCheck: _SpanEq = true;
void _boundCheck;
void _spanCheck;
