import {
	BreakCause,
	BreakContext,
	BreakOrigin,
	BreakReason,
	INVALID_ARGUMENT,
	RouteFailure,
	routeFailureCause,
	routeFailureFromCause,
	UNKNOWN_SWISSNUM_MESSAGE,
} from "@glowcap/abi";
import {
	GlowcapError,
	PublicationNotFound,
	retainCleanupFailures,
	retainSecondaryFailure,
	secondaryFailureCount,
	secondaryFailures,
	VowBroken,
	vowFailure,
} from "../errors.ts";
import { assert } from "../../test/assert.ts";
import { withCleanup } from "../cleanup.ts";

Deno.test("dial reports accept only fresh local route causes", () => {
	for (const route of [RouteFailure.PeerUnreachable, RouteFailure.TransportUnavailable]) {
		const cause = routeFailureCause(route);
		assert(routeFailureFromCause(cause) === route);
		for (const context of [BreakContext.Fetch, BreakContext.Restoration, BreakContext.Withdrawal]) {
			assert(routeFailureFromCause(new BreakCause(cause.origin, cause.reason, context)) === null);
		}
	}
	assert(routeFailureFromCause(BreakCause.partner()) === null);
	assert(routeFailureFromCause(new BreakCause()) === null);
	assert(
		routeFailureFromCause(GlowcapError.transportUnavailable("no connector").breakCause) ===
			RouteFailure.TransportUnavailable,
	);
});

Deno.test("secondary failures retain the exact primary, including when frozen", () => {
	const primary = Object.freeze(new Error("primary"));
	const cleanup = new Error("cleanup");
	assert(retainSecondaryFailure(primary, cleanup) === primary, "the primary error identity changed");
	assert(secondaryFailures(primary).length === 1, "the cleanup failure was not retained");
	assert(secondaryFailures(primary)[0] === cleanup, "the exact cleanup error identity changed");
});

Deno.test("secondary failure retention is bounded and reports the full count", () => {
	const primary = new Error("primary");
	for (let index = 0; index < 65; index++) {
		retainSecondaryFailure(primary, new Error(`cleanup ${index}`));
	}
	assert(secondaryFailures(primary).length === 64, "secondary retention exceeded its bound");
	assert(secondaryFailureCount(primary) === 65, "secondary loss was not reported");
	assert((secondaryFailures(primary)[0] as Error).message === "cleanup 0", "the first consequence moved");
});

Deno.test("repeated cleanup failures remain ordered without duplicating the primary", () => {
	const primary = new Error("primary");
	const first = new Error("first cleanup");
	const second = new Error("second cleanup");
	retainSecondaryFailure(primary, primary);
	retainSecondaryFailure(primary, first);
	retainSecondaryFailure(primary, second);
	assert(secondaryFailures(primary).length === 2, "the retained cleanup count is wrong");
	assert(secondaryFailures(primary)[0] === first, "the first cleanup failure moved");
	assert(secondaryFailures(primary)[1] === second, "the second cleanup failure moved");
});

Deno.test("rollback runs every cleanup and preserves construction as primary", async () => {
	const primary = new Error("construction failed");
	const listener = new Error("listener cleanup failed");
	const loop = new Error("loop cleanup failed");
	const order: string[] = [];
	await retainCleanupFailures(primary, [
		() => {
			order.push("listener");
			throw listener;
		},
		() => {
			order.push("loop");
			return Promise.reject(loop);
		},
	]);
	assert(order.join(",") === "listener,loop", "rollback skipped or reordered an owner");
	assert(secondaryFailures(primary)[0] === listener, "listener cleanup did not stay first");
	assert(secondaryFailures(primary)[1] === loop, "loop cleanup was not retained");
});

Deno.test("an unknown durable publication is a typed lifecycle failure", () => {
	const missing = vowFailure(
		-12,
		"unknown swissnum",
		new BreakCause(BreakOrigin.Partner, BreakReason.Application, BreakContext.Fetch),
	);
	assert(missing instanceof PublicationNotFound, "unknown swissnum remained protocol text");
	assert(missing.reason === "unknown swissnum", "the canonical wire break changed");
	assert(
		!(vowFailure(-12, "application refusal") instanceof PublicationNotFound),
		"an ordinary break was misclassified",
	);
});

Deno.test("local failure predicates depend only on the typed cause", () => {
	const refusal = new GlowcapError(INVALID_ARGUMENT, "PeerIdentityUnverified");
	assert(!refusal.isPeerIdentityUnverified(), "message text answered the predicate");
	const identity = new GlowcapError(INVALID_ARGUMENT, "", BreakCause.local(BreakReason.IdentityUnverified));
	assert(identity.isPeerIdentityUnverified(), "the typed refusal missed the predicate");
	assert(
		new VowBroken("", BreakCause.local(BreakReason.IdentityUnverified)).isPeerIdentityUnverified(),
		"the typed break missed",
	);
	assert(
		new VowBroken("connection refused", BreakCause.local(BreakReason.PeerUnreachable)).isExporterUnreachable(),
		"the typed route failure missed",
	);
});

Deno.test("local publication absence is typed and cannot be forged by lookup diagnostics", () => {
	const absent = new BreakCause(BreakOrigin.Local, BreakReason.PublicationAbsent, BreakContext.Fetch);
	const missing = vowFailure(-12, "diagnostic wording changed", absent);
	assert(missing instanceof PublicationNotFound);
	assert(missing.detail === "diagnostic wording changed");
	for (const reason of [BreakReason.Unspecified, BreakReason.Application]) {
		const diagnostic = new BreakCause(BreakOrigin.Local, reason, BreakContext.Fetch);
		assert(!(vowFailure(-12, UNKNOWN_SWISSNUM_MESSAGE, diagnostic) instanceof PublicationNotFound));
	}
	const route = new BreakCause(BreakOrigin.Local, BreakReason.PeerUnreachable, BreakContext.Fetch);
	assert(new VowBroken("", route).isExporterUnreachable());
	const restored = new BreakCause(route.origin, route.reason, route.context | BreakContext.Restoration);
	assert(!new VowBroken("", restored).isExporterUnreachable());
});

Deno.test("constructor release preserves every primary and runs exactly once", async () => {
	for (const primary of [new Error("installation refused"), null, undefined, 0]) {
		const cleanup = new Error("release failed");
		let releases = 0;
		let caught = false;
		try {
			await withCleanup(() => {
				throw primary;
			}, () => {
				releases++;
				return Promise.reject(cleanup);
			});
		} catch (error) {
			caught = true;
			assert(Object.is(error, primary), "release replaced the installation failure");
		}
		assert(caught, "installation refusal resolved");
		assert(releases === 1, "constructor release was skipped or repeated");
		if (primary instanceof Error) {
			assert(secondaryFailures(primary)[0] === cleanup, "release failure was lost");
		}
	}
});

Deno.test("constructor success waits for release", async () => {
	const order: string[] = [];
	await withCleanup(() => {
		order.push("install");
	}, async () => {
		await Promise.resolve();
		order.push("release");
	});
	assert(order.join(",") === "install,release", "release barrier was not joined");
});

Deno.test("constructor release failure after success is returned without a retry", async () => {
	const cleanup = new Error("release failed");
	let releases = 0;
	let caught = false;
	try {
		await withCleanup(() => {}, () => {
			releases++;
			throw cleanup;
		});
	} catch (error) {
		caught = true;
		assert(error === cleanup, "release-only failure changed");
	}
	assert(caught && releases === 1, "release-only failure was hidden or retried");
});

Deno.test("rollback never assimilates a thrown thenable", async () => {
	let thenCalls = 0;
	const primary = Object.freeze({
		then() {
			thenCalls++;
			throw new Error("thrown reason was awaited");
		},
	});
	const cleanup = new Error("release failed");
	await retainCleanupFailures(primary, []);
	let caught = false;
	try {
		await withCleanup(() => {
			throw primary;
		}, () => Promise.reject(cleanup));
	} catch (error) {
		caught = true;
		assert(error === primary, "thenable reason was replaced");
	}
	assert(caught && thenCalls === 0, "rollback assimilated the primary reason");
	assert(secondaryFailures(primary)[0] === cleanup, "thenable primary lost its cleanup failure");
});

Deno.test("partner break text cannot forge a local failure cause", () => {
	for (
		const reason of [
			"unknown swissnum",
			"PeerIdentityUnverified",
			"ExporterUnreachable: glowcap error -8: peer-unreachable: x",
			"handoff redeem failed: x",
		]
	) {
		const failure = vowFailure(-12, reason, BreakCause.partner());
		assert(!(failure instanceof PublicationNotFound), "partner text forged a missing publication");
		assert(!failure.isPeerIdentityUnverified(), "partner text forged an identity refusal");
		assert(!failure.isExporterUnreachable(), "partner text forged an unreachable exporter");
	}
});

Deno.test("cleanup preserves the primary failure provenance", () => {
	const primary = new VowBroken("refused", BreakCause.local(BreakReason.IdentityUnverified));
	const cleanup = new Error("cleanup");
	retainSecondaryFailure(primary, cleanup);
	assert(primary.isPeerIdentityUnverified(), "cleanup replaced the core's typed provenance");
	assert(secondaryFailures(primary)[0] === cleanup, "cleanup was discarded");
});

Deno.test("unknown ABI cause retains the original failure and reports the mismatch", () => {
	const failure = vowFailure(-12, "original refusal", { origin: 999, reason: 0, context: 0 });
	assert(failure instanceof VowBroken && failure.reason === "original refusal", "original failure was replaced");
	assert(
		failure.breakCause.origin === BreakOrigin.Unspecified &&
			failure.breakCause.reason === BreakReason.Unspecified && failure.breakCause.context === 0,
		"unknown provenance became trusted",
	);
	assert(secondaryFailures(failure).length === 1, "ABI mismatch disappeared");
});

Deno.test("application messages exclude fetch and restoration diagnostics", () => {
	for (const context of [BreakContext.Fetch, BreakContext.Restoration, BreakContext.Withdrawal]) {
		const cause = new BreakCause(BreakOrigin.Partner, BreakReason.Application, context);
		assert(
			new VowBroken("rate-limited: forged diagnostic", cause).applicationMessage() === null,
			"operation wrapper became application advice",
		);
	}
	assert(
		new VowBroken("application refusal", BreakCause.partner()).applicationMessage() === "application refusal",
		"application message was lost",
	);
});

Deno.test("publication miss query requires exact partner fetch text or a typed local miss", () => {
	for (const origin of [BreakOrigin.Unspecified, BreakOrigin.Local, BreakOrigin.Partner]) {
		for (const reason of [BreakReason.Unspecified, BreakReason.Application, BreakReason.PublicationAbsent]) {
			for (let context = 0; context < 8; context++) {
				const cause = new BreakCause(origin, reason, context);
				for (const message of [UNKNOWN_SWISSNUM_MESSAGE, "unknown swissnum: forged", "", "other refusal"]) {
					const expected = context === BreakContext.Fetch && (
						(origin === BreakOrigin.Local && reason === BreakReason.PublicationAbsent) ||
						(origin === BreakOrigin.Partner && reason === BreakReason.Application &&
							message === UNKNOWN_SWISSNUM_MESSAGE)
					);
					assert(cause.isPublicationNotFound(message) === expected);
				}
			}
		}
	}
});
