/**
 * The observation a scrubber drag retimes: named when the plan is
 * event-addressed, absent when the painted span has no observation.
 */

import { assertEquals } from "@std/assert";
import { eventIdOfPlan } from "./scrubber-drag.ts";
import type { ScrubberHit } from "./hit-test.ts";

Deno.test("an event-addressed plan names the observation it retimes", () => {
	const hit: ScrubberHit = {
		entity: { kind: "peer", id: "alice" },
		drag: { kind: "span-body", eventId: "join-alice", originalT: 0 },
	};
	assertEquals(eventIdOfPlan(hit), "join-alice");
});

Deno.test("an entity-addressed plan names no observation", () => {
	const hit: ScrubberHit = {
		entity: { kind: "peer", id: "alice" },
		drag: {
			kind: "entity-span-body",
			ref: { kind: "peer", id: "alice" },
			originalT: 0,
		},
	};
	assertEquals(eventIdOfPlan(hit), null);
});

Deno.test("a hit with no drag plan names no observation", () => {
	const hit: ScrubberHit = {
		entity: { kind: "message", id: "m1" },
		drag: null,
	};
	assertEquals(eventIdOfPlan(hit), null);
});
