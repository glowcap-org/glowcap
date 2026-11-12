// The session's activity reader learns from its first read where what already
// happened ends, and tells its presentation owner which is which.
import { assertEquals } from "../assert.ts";
import type { ActivityRead, ObservationView } from "../../web/ui/session/managed/model.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";

Deno.test("what the journal held when a reader began is the past, and again after a gap", async () => {
	const parked = deferred<ObservationView>();
	const update: ObservationView = {
		cursor: new Uint8Array(56),
		source: { status: "active", effective: { permissions: ["observeWorkspace"] } },
		changed: true,
		resync: false,
	};
	const event = (cursor: string, head: string): ActivityRead => ({
		cursor,
		head,
		event: { at: 0, target: { kind: "directory", id: "directory" }, notice: null },
	});
	// The journal ends at 2 when the reader begins. Event 3 arrives while it
	// reads, so 3 is news though no read has yet found the journal empty.
	const pages: ActivityRead[] = [
		event("1", "2"),
		event("2", "3"),
		event("3", "3"),
		event("4", "4"),
		{ cursor: "6", head: "8", gap: true },
		event("7", "9"),
		event("8", "9"),
		event("9", "9"),
	];
	const idle = deferred<ActivityRead>();
	const drained = deferred<void>();
	const reads: [string, boolean][] = [];
	const delivered: [string, boolean][] = [];
	let resynchronized = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		resynchronizeDiscovery: () => {
			resynchronized++;
			return Promise.resolve();
		},
		prepareObservation: () =>
			Promise.resolve({
				submit: () =>
					Promise.resolve({
						poll: () => Promise.resolve(update),
						receive: () => parked.promise,
						cancel: () => {
							parked.resolve(update);
							return Promise.resolve();
						},
						free() {},
					}),
				free() {},
			}),
		activityReader: () =>
			Promise.resolve({
				read: (cursor: string, wait: boolean) => {
					reads.push([cursor, wait]);
					const page = pages.shift();
					if (page != null) return Promise.resolve(page);
					drained.resolve();
					return idle.promise;
				},
				cancel: () => {
					idle.resolve({ cursor: "9", head: "9" });
					return Promise.resolve();
				},
				free() {},
			}),
	});
	const stop = session.onActivity((delivery) => {
		const replayed = delivery.replayed;
		delivered.push([delivery.take().cursor, replayed]);
	});
	try {
		await session.start();
		await drained.promise;
		assertEquals(reads, [
			["", false],
			["1", false],
			["2", false],
			["3", true],
			["4", true],
			["6", false],
			["7", false],
			["8", false],
			["9", true],
		]);
		assertEquals(delivered, [
			["1", true],
			["2", true],
			["3", false],
			["4", false],
			["6", false],
			["7", true],
			["8", true],
			["9", false],
		]);
		assertEquals(resynchronized, 1);
	} finally {
		stop();
		idle.resolve({ cursor: "9", head: "9" });
		await session.close();
	}
});

Deno.test("a failed read and a stretch with no reader both leave activity to catch up on", async () => {
	const parked = deferred<ObservationView>();
	const update: ObservationView = {
		cursor: new Uint8Array(56),
		source: { status: "active", effective: { permissions: ["observeWorkspace"] } },
		changed: true,
		resync: false,
	};
	const event = (free: () => void) => ({
		cursor: "2",
		head: "2",
		event: { at: 0, target: { kind: "directory", id: "directory" }, notice: null, files: [{ free }] },
	});
	const unread = deferred<unknown>();
	const released = deferred<void>();
	const idle = deferred<unknown>();
	// One step per read, in order. An event the reader may not see is still
	// part of the past it is catching up on.
	const steps: (() => Promise<unknown>)[] = [
		() => Promise.resolve({ cursor: "1", head: "1", unavailable: true }),
		() => Promise.resolve({ cursor: "1", head: "1" }),
		() => Promise.reject(new Error("connection ended")),
		() => Promise.resolve({ cursor: "1", head: "1" }),
		() => unread.promise,
		() => Promise.resolve(event(() => {})),
		() => Promise.resolve({ cursor: "2", head: "2" }),
		() => idle.promise,
	];
	const reads: [string, boolean][] = [];
	const asked = steps.map(() => deferred<void>());
	const delivered: [string, boolean][] = [];
	const refused = deferred<void>();
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareObservation: () =>
			Promise.resolve({
				submit: () =>
					Promise.resolve({
						poll: () => Promise.resolve(update),
						receive: () => parked.promise,
						cancel: () => {
							parked.resolve(update);
							return Promise.resolve();
						},
						free() {},
					}),
				free() {},
			}),
		activityReader: () =>
			Promise.resolve({
				read: (cursor: string, wait: boolean) => {
					asked[reads.length]?.resolve();
					reads.push([cursor, wait]);
					const step = steps.shift();
					return step == null ? idle.promise : step();
				},
				cancel: () => {
					idle.resolve({ cursor: "2", head: "2" });
					return Promise.resolve();
				},
				free() {},
			}),
	}, () => refused.resolve());
	const follow = () =>
		session.onActivity((delivery) => {
			const replayed = delivery.replayed;
			delivered.push([delivery.take().cursor, replayed]);
		});
	let stop = follow();
	try {
		await session.start();
		await refused.promise;
		assertEquals(reads, [["", false], ["1", false], ["1", true]], "the read that failed waited");
		session.retryUpdates();
		await asked[4].promise;
		assertEquals(reads.slice(3), [["1", false], ["1", true]], "a failed read may have missed activity");
		// The parked read answers while nobody reads. Its event stays unread.
		stop();
		unread.resolve(event(() => released.resolve()));
		await released.promise;
		stop = follow();
		await asked[7].promise;
		assertEquals(reads.slice(5), [["1", false], ["2", false], ["2", true]]);
		assertEquals(delivered, [["1", true], ["1", false], ["1", false], ["2", true], ["2", false]]);
	} finally {
		stop();
		idle.resolve({ cursor: "2", head: "2" });
		await session.close();
	}
});
