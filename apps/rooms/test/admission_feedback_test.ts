// Refusals preserve intent and isolate room cooldowns. Expiry schedules nothing.
/// <reference lib="dom" />
import { assert, assertEquals } from "./assert.ts";
import { RoomsError } from "../lib/error_codes.ts";
import {
	activeRefusal,
	clearRefusal,
	joinRefusalKeys,
	remaining,
	rememberJoinRefusal,
	rememberRefusal,
} from "../web/ui/admission_feedback.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const { PageProjection } = await import("../web/ui/store/core.ts");
const { membershipStatus } = await import("../web/ui/session/managed/membership_status.ts");

Deno.test("membership snapshots cannot renew expired advice or clear a newer gesture", () => {
	const descriptor = Object.getOwnPropertyDescriptor(performance, "now");
	let now = 0;
	Object.defineProperty(performance, "now", { configurable: true, value: () => now });
	try {
		const projection = new PageProjection();
		let reports = 0;
		const update = membershipStatus(projection, () => reports++);
		const failure = {
			target: { kind: "directory", id: "directory" },
			reason: "rate-limited: retry-after-ms=1000; scope=join",
		};
		update({ failures: [failure] });
		const original = projection.get().actionRefusals.get("join:directory")!;
		assertEquals(original.until, 1000);
		now = 1001;
		update({ failures: [failure] });
		assert(projection.get().actionRefusals.get("join:directory") === original, "snapshot renewed expired advice");
		assertEquals(remaining(original), 0);
		rememberJoinRefusal(projection, "directory", "room", failure.reason);
		const gesture = projection.get().actionRefusals.get("join:directory")!;
		assert(gesture !== original, "new explicit gesture did not acquire its own feedback");
		update({ failures: [failure] });
		update({ failures: [] });
		assert(projection.get().actionRefusals.get("join:directory") === gesture, "old report cleared newer feedback");
		now = 2002;
		update({ failures: [failure] });
		assertEquals(projection.get().actionRefusals.get("join:directory")?.until, 3002);
		assertEquals(reports, 2, "unchanged reports must not grow the journal");
		update({ failures: [] });
		assertEquals(projection.get().actionRefusals.size, 0);
	} finally {
		if (descriptor == null) Reflect.deleteProperty(performance, "now");
		else Object.defineProperty(performance, "now", descriptor);
	}
});
Deno.test("room quota preserves draft and does not block another room or directory", () => {
	const projection = new PageProjection();
	const drafts = projection.get().drafts;
	const room = new RoomsError("rate-limited", "retry-after-ms=1000; scope=room-join");
	rememberJoinRefusal(projection, "directory", "Garden", room);
	const same = activeRefusal(projection.get().actionRefusals, joinRefusalKeys("directory", "Garden"));
	assert(remaining(same) > 0, "original room has cooldown");
	assertEquals(activeRefusal(projection.get().actionRefusals, joinRefusalKeys("directory", "Other")), undefined);
	assertEquals(
		activeRefusal(projection.get().actionRefusals, joinRefusalKeys("other-directory", "Garden")),
		undefined,
	);
	rememberJoinRefusal(projection, "directory", "Garden", room);
	assertEquals(
		activeRefusal(projection.get().actionRefusals, joinRefusalKeys("directory", "Garden"))?.until,
		same?.until,
	);
	assert(projection.get().drafts === drafts, "refusal must preserve exact draft custody");
	assertEquals(remaining(same, same!.until! + 1), 0);
	const aggregate = new RoomsError("rate-limited", "retry-after-ms=2000; scope=join");
	rememberJoinRefusal(projection, "directory", "Garden", aggregate);
	assert(
		remaining(activeRefusal(projection.get().actionRefusals, joinRefusalKeys("directory", "Other"))) > 0,
		"aggregate applies across rooms",
	);
});
Deno.test("malformed advice cannot create a timer and capacity cannot invent a delay", () => {
	const projection = new PageProjection();
	rememberRefusal(projection, "send:one", new RoomsError("rate-limited", "retry-after-ms=999999999; scope=message"));
	assertEquals(remaining(projection.get().actionRefusals.get("send:one")), 0);
	clearRefusal(projection, "send:one");
	rememberRefusal(projection, "send:one", new RoomsError("admission-busy", "accounting full"));
	assertEquals(projection.get().actionRefusals.get("send:one")?.until, null);
	assertEquals(rememberRefusal(projection, "send:two", new Error("unknown retry-after-ms=1000")), false);
	assertEquals(
		rememberRefusal(projection, "send:large", new RoomsError("request-too-large", "scope=message-bytes")),
		true,
	);
	assertEquals(projection.get().actionRefusals.get("send:large")?.until, null);
	const attributed = new RoomsError("rate-limited", "retry-after-ms=1000; scope=room-join; owner=directory");
	assertEquals(attributed.retryAfterMs, 1000);
	assertEquals(attributed.retryScope, "room-join");
	for (const owner of ["unknown", "session; owner=http"]) {
		assertEquals(
			new RoomsError("rate-limited", `retry-after-ms=1000; scope=join; owner=${owner}`).retryAfterMs,
			null,
		);
	}
});
