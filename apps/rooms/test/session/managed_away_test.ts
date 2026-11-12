// A page attached to a session elsewhere says the session is away when a read
// loses its connection, and stops saying so when a read answers.
import { assertEquals } from "../assert.ts";
import type { ObservationView } from "../../web/ui/session/managed/model.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";

function failure(status: number, reason: string, code: string | null): Error {
	return Object.assign(new Error(`glowcap error ${status}: ${reason}`), { status, reason, code, detail: reason });
}
const update: ObservationView = {
	cursor: new Uint8Array(56),
	source: { status: "active", effective: { permissions: ["observeWorkspace"] } },
	changed: true,
	resync: false,
};

/** A viewer whose second snapshot fails with `first`, then with `second`, then answers. */
function failing(local: boolean, first: Error, second: Error) {
	const parked = deferred<ObservationView>();
	const steps = [deferred<void>(), deferred<void>(), deferred<void>()];
	let snapshots = 0;
	let receives = 0;
	const observation = {
		poll: () => Promise.resolve(update),
		receive: () => ++receives === 1 ? Promise.resolve(update) : parked.promise,
		cancel: () => {
			parked.resolve(update);
			return Promise.resolve();
		},
		free() {},
	};
	const session = viewer(
		{
			snapshot: () => {
				snapshots++;
				if (snapshots === 2) return Promise.reject(first);
				if (snapshots === 3) return Promise.reject(second);
				return Promise.resolve(snapshot());
			},
			prepareObservation: () => Promise.resolve({ submit: () => Promise.resolve(observation), free() {} }),
		},
		() => steps[snapshots - 2]?.resolve(),
		{},
		local,
	);
	const stop = session.subscribe(() => {
		if (snapshots >= 4 && session.updatesFailure == null) steps[2].resolve();
	});
	return { session, steps, stop };
}

Deno.test("a read that loses its connection marks a session elsewhere away until a read answers", async () => {
	const closed = failure(-7, "session closing", null);
	const dead = failure(-13, "host: UnknownCapability", null);
	const { session, steps, stop } = failing(false, closed, dead);
	await session.start();
	await steps[0].promise;
	assertEquals(session.away, true);
	// What the dead link answers next names no connection, and the session is still away.
	session.retryUpdates();
	await steps[1].promise;
	assertEquals([session.away, session.updatesFailure], [true, dead]);
	session.retryUpdates();
	await steps[2].promise;
	assertEquals([session.away, session.updatesFailure], [false, null]);
	stop();
	await session.close();
});

Deno.test("a refusal the session answered, and any failure of a session this browser runs, is not away", async () => {
	const refused = failure(-12, "Denied", null);
	const closed = failure(-7, "session closing", null);
	const cases: [boolean, Error][] = [[false, refused], [true, closed]];
	for (const [local, first] of cases) {
		const { session, steps, stop } = failing(local, first, first);
		await session.start();
		await steps[0].promise;
		assertEquals([session.away, session.updatesFailure], [false, first]);
		stop();
		await session.close();
	}
});
