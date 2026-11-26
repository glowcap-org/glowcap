// The session's activity reader learns from its first read where what already
// happened ends, and tells its presentation owner which is which.
import { assertEquals } from "../assert.ts";
import type { ActivityRead, ObservationView } from "../../web/ui/session/managed/model.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { linkedWorkspace, relinking } from "../support/managed_link.ts";
import { until } from "../support/wait.ts";
import { catchUp } from "../../web/ui/session/managed/activity_reading.ts";

const at = (cursor: string, head: string): ActivityRead => ({
	cursor,
	head,
	event: { at: 0, target: { kind: "directory", id: "directory" }, notice: null },
});

Deno.test("a link replaced while the presentation owner takes an event leaves the outage's events to catch up on", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	// The first read finds the journal empty, so event 2 is news.
	first.script.push({ reply: () => ({ cursor: "run:1", head: "run:1" }) }, { reply: () => at("run:2", "run:2") });
	// Event 3 happened while the link was away.
	second.script.push({ reply: () => at("run:3", "run:3") });
	const { session } = relinking(first.workspace, second.workspace);
	const taking = deferred<void>();
	const delivered: [string, boolean][] = [];
	session.onActivity(async (delivery) => {
		const replayed = delivery.replayed;
		const page = delivery.take();
		if (page.event == null) return;
		delivered.push([page.cursor, replayed]);
		if (page.cursor === "run:2") await taking.promise;
	});
	await session.start();
	await until(() => delivered.length === 1, "the news event");
	first.lose();
	await until(() => first.state.freed === 1 && session.link?.live === true, "the new link");
	taking.resolve();
	await until(() => delivered.length === 2, "the outage's event");
	assertEquals(delivered, [["run:2", false], ["run:3", true]]);
	assertEquals(second.reads[0], "run:2", "the new link reads on from the event taken");
	second.lose();
	await session.close();
});

Deno.test("what the journal held when a reader began is the past, and again after a gap", async () => {
	const parked = deferred<ObservationView>();
	const update: ObservationView = {
		cursor: new Uint8Array(56),
		source: { status: "active", effective: { permissions: ["observeWorkspace"] } },
		changed: true,
		resync: false,
	};
	// The journal ends at 2 when the reader begins. Event 3 arrives while it
	// reads, so 3 is news though no read has yet found the journal empty.
	const pages: ActivityRead[] = [
		at("1", "2"),
		at("2", "3"),
		at("3", "3"),
		at("4", "4"),
		{ cursor: "6", head: "8", gap: true },
		at("7", "9"),
		at("8", "9"),
		at("9", "9"),
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

// Where one read leaves a reader, by what it was behind and what the read said.
const quiet = (cursor: string, head: string): ActivityRead<unknown> => ({ cursor, head });
const reads: [string, Parameters<typeof catchUp>, ReturnType<typeof catchUp>][] = [
	["news to a reader that is not behind", [null, at("run:5", "run:5"), false, "run:4"], {
		replayed: false,
		after: null,
	}],
	[
		"the past to a reader behind a head it has not reached",
		[{ head: "run:5" }, at("run:3", "run:6"), false, "run:2"],
		{
			replayed: true,
			after: { head: "run:5" },
		},
	],
	["the last of the past to a reader at the head it was behind", [
		{ head: "run:5" },
		at("run:6", "run:6"),
		false,
		"run:5",
	], {
		replayed: false,
		after: null,
	}],
	["an empty read to a reader behind", [{ head: "run:5" }, quiet("run:2", "run:2"), false, "run:2"], {
		replayed: false,
		after: null,
	}],
	["a first read, which learns where the journal ends", [{ head: null }, at("run:1", "run:3"), false, ""], {
		replayed: true,
		after: { head: "run:3" },
	}],
	["a gap, which moves the head to where the journal ends now", [
		{ head: "run:5" },
		{ ...at("run:7", "run:9"), gap: true },
		false,
		"run:2",
	], {
		replayed: true,
		after: { head: "run:9" },
	}],
	["a restart, which leaves the reader behind with no head", [
		{ head: "run:5" },
		{ cursor: "", gap: true, head: "" },
		true,
		"run:4",
	], {
		replayed: true,
		after: { head: null },
	}],
];
for (const [name, args, expected] of reads) {
	Deno.test(`a read is ${name}`, () => {
		assertEquals(catchUp(...args), expected);
	});
}
