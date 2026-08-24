// Shared assertions and ledger open/close for live-feed tests.

import { assert } from "@std/assert";
import type { BaseTimelineEvent } from "../record.ts";
import type { TimelineEvent } from "../../timeline.ts";

/**
 * Narrow `TimelineEvent | undefined` to a specific `kind`. Returns
 * the event so the caller can chain field access without further
 * non-null / discriminant gymnastics.
 *
 * This pattern repeats across the suite because `assertEquals` is not
 * a TypeScript predicate — it asserts at runtime but does not narrow
 * the type, and `noUncheckedIndexedAccess` returns `T | undefined`
 * from array indexing.
 */
export function expectKind<K extends TimelineEvent["kind"]>(
	ev: TimelineEvent | undefined,
	kind: K,
): Extract<TimelineEvent, { kind: K }> {
	assert(ev !== undefined, `expected event of kind ${kind}, got undefined`);
	assert(
		ev.kind === kind,
		`expected event of kind ${kind}, got ${ev.kind}`,
	);
	return ev as Extract<TimelineEvent, { kind: K }>;
}

export function openSession(
	convert: (ev: BaseTimelineEvent) => TimelineEvent[],
	session: string,
	b: string,
	t_ns: number,
): TimelineEvent[] {
	return convert({
		v: 1,
		sim_t_ns: t_ns,
		kind: "ocapn.session-opened",
		session,
		a: "rooms",
		b,
		codec: "syrup",
	});
}

export function closeSession(
	convert: (ev: BaseTimelineEvent) => TimelineEvent[],
	session: string,
	t_ns: number,
): TimelineEvent[] {
	return convert({
		v: 1,
		sim_t_ns: t_ns,
		kind: "ocapn.session-closed",
		session,
	});
}
