// Viewer failures retain the accepted projection, original cursor and exact
// wrapper ownership. Rust browser proofs separately exercise actual authority.
import { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import { assert, assertEquals } from "../assert.ts";
import { ActivityDelivery, releaseActivity } from "../../web/ui/session/managed/activity.ts";
import type { ActivityPage, ObservationView } from "../../web/ui/session/managed/model.ts";
import { ManagedOperation } from "../../web/ui/session/managed/operation.ts";
import { completeResult } from "../../web/ui/session/managed/completion.ts";
import type { RoomsManagedApplication, RoomsManagedWorkspace } from "../../../../zig-out/wasm/rooms/rooms_browser.js";

import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";

for (const consumer of ["refresh", "candidate", "command"] as const) {
	Deno.test(`${consumer} uses the accepted revision when an older snapshot finishes later`, async () => {
		const older = deferred<ReturnType<typeof snapshot>>();
		const started = deferred<void>();
		let reads = 0;
		let prepared = "";
		const latest = { ...snapshot(), revision: "2" };
		const session = viewer({
			snapshot: () => {
				if (++reads !== 1) return Promise.resolve(latest);
				started.resolve();
				return older.promise;
			},
			prepareCommand: (_id: string, revision: string) => {
				prepared = revision;
				return Promise.resolve({
					submit: () => Promise.resolve("committed"),
					status: () => Promise.resolve("committed"),
					free() {},
				});
			},
		});
		try {
			const reading = consumer === "command" ? session.command("select", ["room"]) : session[consumer]();
			await started.promise;
			await session.refresh();
			older.resolve(snapshot());
			const result = await reading;
			if (result instanceof ManagedOperation) {
				session.finish(result);
				assertEquals(prepared, "2");
			} else {
				assertEquals(result.revision, "2");
				if (consumer === "candidate") assert(result !== latest, "editable candidates own their copy");
			}
			assertEquals(session.current, latest);
			assertEquals(reads, consumer === "command" ? 3 : 2, "reuse accepted evidence without another read");
		} finally {
			await session.close();
		}
	});
}

Deno.test("managed command admission reads past a delayed presentation revision", async () => {
	let current = snapshot();
	let prepared = "";
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		prepareCommand: (_operation: string, revision: string) => {
			prepared = revision;
			return Promise.resolve({
				submit: () => Promise.resolve("committed"),
				status: () => Promise.resolve("committed"),
				originalIntent: () => ["operation", Number(revision), "select", ["room"]],
				free() {},
			});
		},
	});
	await session.refresh();
	current = { ...snapshot(), revision: "2" };
	assertEquals(session.current?.revision, "1");
	const operation = await session.command("select", ["room"]);
	assertEquals(prepared, "2");
	session.finish(operation);
	await session.close();
});

for (const outcome of ["registered", "replaced", "cancelled"] as const) {
	Deno.test(`managed directory readiness retains its original choice: ${outcome}`, async () => {
		const current = snapshot();
		const original = {
			id: "directory",
			access: "access",
			source: "source",
			home: true,
			nick: "ada",
			nickAllocation: "exact" as const,
			standing: null,
		};
		current.intent.directories.push(original);
		const session = viewer({ snapshot: () => Promise.resolve(current) });
		await session.refresh();
		const abort = new AbortController();
		let settled = false;
		const ready = session.directoryRegistered(original, abort.signal).finally(() => settled = true);
		const result = Promise.allSettled([ready]);
		await Promise.resolve();
		assertEquals(settled, false, "directory custody alone supplies no registered name");
		if (outcome === "cancelled") abort.abort();
		else {
			current.intent.directories[0] = outcome === "registered"
				? { ...original, name: "registration", assignedNick: "ada" }
				: { ...original, source: "replacement" };
			await session.refresh();
		}
		assertEquals((await result)[0].status, outcome === "replaced" ? "rejected" : "fulfilled");
		await session.close();
	});
}

Deno.test("cold managed result adoption survives a lost acknowledgement and later workspace changes", async () => {
	let current = snapshot();
	current.intent.directories.push({
		id: "directory",
		access: "access",
		home: true,
		nick: "nick",
		nickAllocation: "exact",
		standing: null,
	});
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	let adopted = false;
	let acquisitions = 0;
	const recovered = () =>
		new ManagedOperation(
			"original",
			{
				originalIntent: () => ["original", 1, "openManagedRoom", ["directory", "Room"]],
				adopted: () => Promise.resolve(adopted),
				result: () => Promise.resolve({ room: "original-room", control: "original-control" }),
				prepareCreatedRoomAcquisition: (
					_revision: string,
					_mappings: string,
					_releases: string,
					intent: string,
				) => Promise.resolve({
					submit: () => {
						acquisitions++;
						current = { ...current, intent: JSON.parse(intent) };
						adopted = true;
						return Promise.reject(new Error("lost adoption acknowledgement"));
					},
					free() {},
				}),
			} as unknown as ConstructorParameters<typeof ManagedOperation>[1],
		);
	await completeResult(session, recovered()).catch(() => {});
	assert(adopted, "the first adoption committed before its acknowledgement was lost");
	assertEquals(current.intent.conversations.length, 1);
	current.intent.standing = "later change";
	await completeResult(session, recovered());
	assertEquals(acquisitions, 1);
	assertEquals(current.intent.conversations[0].id, "original");
	assertEquals(current.intent.standing, "later change");
	await session.close();
});

Deno.test("managed observation retries a failed projection with its original registration and cursor", async () => {
	const accepted = snapshot();
	const reported = deferred<void>();
	const recovered = deferred<void>();
	const parked = deferred<ObservationView>();
	const update: ObservationView = {
		cursor: new Uint8Array(56),
		source: { status: "active", effective: { permissions: ["observeWorkspace"] } },
		changed: true,
		resync: false,
	};
	let snapshots = 0;
	let receives = 0;
	let registrations = 0;
	let fail = true;
	const observation = {
		poll: () => Promise.resolve(update),
		receive: (cursor: Uint8Array) => {
			assert(cursor === update.cursor, "retry must keep the accepted cursor");
			receives++;
			return receives === 1 ? Promise.resolve(update) : parked.promise;
		},
		cancel: () => {
			parked.resolve(update);
			return Promise.resolve();
		},
		free() {},
	};
	const session = viewer({
		snapshot: () => {
			snapshots++;
			return snapshots > 1 && fail
				? Promise.reject(new Error("snapshot unavailable"))
				: Promise.resolve(accepted);
		},
		prepareObservation: () => {
			registrations++;
			return Promise.resolve({ submit: () => Promise.resolve(observation), free() {} });
		},
	}, () => reported.resolve());
	await session.start();
	await reported.promise;
	assertEquals(receives, 1);
	assertEquals(registrations, 1);
	fail = false;
	const stop = session.subscribe(() => {
		if (snapshots >= 3 && session.updatesFailure == null) recovered.resolve();
	});
	session.retryUpdates();
	assertEquals(session.updatesRetrying, true);
	await recovered.promise;
	assertEquals([session.updatesRetrying, session.updatesFailure], [false, null]);
	assertEquals(registrations, 1);
	stop();
	await session.close();
});

Deno.test("activity failure waits for another change before retrying its exact reader", async () => {
	const parked = deferred<ObservationView>();
	const update: ObservationView = {
		cursor: new Uint8Array(56),
		source: { status: "active", effective: { permissions: ["observeWorkspace"] } },
		changed: true,
		resync: false,
	};
	const reported = deferred<void>();
	const activity = deferred<ActivityPage>();
	let reads = 0;
	let readers = 0;
	const reader = {
		read: (cursor: string) => {
			assertEquals(cursor, "");
			reads++;
			// Park a mistaken second read so the regression cannot starve the
			// harness the way a permanently refused live connection would.
			return reads === 1 ? Promise.reject(new Error("connection ended")) : activity.promise;
		},
		cancel: () => {
			activity.resolve({ cursor: "", gap: false });
			return Promise.resolve();
		},
		free() {},
	};
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
		activityReader: () => {
			readers++;
			return Promise.resolve(reader);
		},
	}, () => reported.resolve());
	const stop = session.onActivity(() => {});
	try {
		await session.start();
		await reported.promise;
		for (let turn = 0; turn < 20; turn++) await Promise.resolve();
		assertEquals(reads, 1, "reporting a failed read must not trigger another read");
		session.retryUpdates();
		for (let turn = 0; turn < 20; turn++) await Promise.resolve();
		assertEquals([reads, readers], [2, 1], "an explicit retry retains the exact reader and cursor");
	} finally {
		stop();
		activity.resolve({ cursor: "", gap: false });
		await session.close();
	}
});

Deno.test("managed close drains preparation and releases a late command exactly once", async () => {
	const preparing = deferred<unknown>();
	const started = deferred<void>();
	let released = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () => {
			started.resolve();
			return preparing.promise;
		},
	});
	const command = session.command("select", ["original-conversation"]);
	const result = Promise.allSettled([command]);
	await started.promise;
	const closing = session.close();
	preparing.resolve({ free: () => released++ });
	await closing;
	assertEquals((await result)[0].status, "rejected");
	assertEquals(released, 1);
	await session.close();
	assertEquals(released, 1);
});

Deno.test("managed activity custody transfers all handles once across presentation failure", () => {
	let released = 0;
	const handle = { free: () => released++ };
	const page = {
		cursor: "original",
		event: { target: { kind: "room", id: "room" }, notice: {}, files: [handle], authority: handle, route: handle },
	} as unknown as ActivityPage;
	const rejected = new ActivityDelivery(page);
	rejected.close();
	rejected.close();
	assertEquals(released, 3);
	const offered = new ActivityDelivery(page);
	const accepted = offered.take();
	offered.close();
	assertEquals(released, 3, "the reader cannot release handles after ownership transfers");
	releaseActivity(accepted);
	assertEquals(released, 6);
});

Deno.test("managed typing coalesces a burst and frees the original sender after shutdown drains", async () => {
	const call = deferred<void>();
	const entered = deferred<void>();
	const values: boolean[] = [];
	let freed = 0;
	const session = viewer({
		typingSender: () =>
			Promise.resolve({
				set(on: boolean) {
					values.push(on);
					entered.resolve();
					return call.promise;
				},
				free() {
					freed++;
				},
			}),
	});
	const first = session.typing.set("room", "seat", true);
	await entered.promise;
	for (let i = 0; i < 1000; i++) session.typing.set("room", "seat", i % 2 === 0);
	session.typing.set("room", "seat", false);
	call.resolve();
	await first;
	assertEquals(values, [true, false]);
	await session.close();
	assertEquals(freed, 1);
});

Deno.test("managed workspace selection rejects a different gesture while original preparation waits", async () => {
	const attaching = deferred<RoomsManagedWorkspace>();
	let preparations = 0;
	const custody = {
		free() {},
		prepareSelectWorkspace: () => {
			preparations++;
			return Promise.resolve({ submit: () => Promise.resolve("committed"), free() {} });
		},
	} as unknown as RoomsManagedWorkspace;
	const application = {
		attachWorkspace: () => attaching.promise,
		close: () => Promise.resolve(),
		free() {},
	} as unknown as RoomsManagedApplication;
	const session = new ManagedRoomsSession(application, custody, custody, () => {});
	const first = session.selectWorkspace("original");
	let refused = false;
	try {
		await session.selectWorkspace("replacement");
	} catch {
		refused = true;
	}
	assert(refused, "a replacement cannot borrow the first gesture's success");
	attaching.resolve({ free() {} } as RoomsManagedWorkspace);
	await first;
	assertEquals(preparations, 1);
	await session.close();
});

Deno.test("managed recovery coalesces the original completion across concurrent callers", async () => {
	let recoveries = 0;
	let completions = 0;
	const completion = deferred<void>();
	const entered = deferred<void>();
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () =>
			Promise.resolve({
				submit: () => Promise.reject(new Error("commit acknowledgment missing")),
				status: () => Promise.resolve("committed"),
				free() {},
			}),
		recoverEffect: () =>
			Promise.resolve({
				status: () => Promise.resolve("pending"),
				resume: () => {
					recoveries++;
					return Promise.resolve("committed");
				},
				free() {},
			}),
	});
	await session.refresh();
	await Promise.allSettled([
		session.execute("original", () => session.command("select", [], "original"), async (operation) => {
			completions++;
			entered.resolve();
			await completion.promise;
			session.finish(operation);
		}),
	]);
	const first = session.completeOperation("original");
	const second = session.completeOperation("original");
	assert(first === second, "recovery must join the original completion, including its acquisition");
	await entered.promise;
	assertEquals(recoveries, 0, "the retained committed request completes without privileged recovery");
	assertEquals(completions, 1);
	completion.resolve();
	assertEquals(await first, true);
	assertEquals(session.pending, []);
	await session.close();
});

Deno.test("managed result recovery joins acquisition preparation and close drains its late wrapper", async () => {
	const preparing = deferred<unknown>();
	let submissions = 0;
	let freed = 0;
	const operation = new ManagedOperation(
		"original",
		{
			prepareResultAcquisition: () => preparing.promise,
			free() {
				freed++;
			},
		} as unknown as import("../../../../zig-out/wasm/rooms/rooms_browser.js").RoomsManagedCommand,
	);
	const first = operation.acquire(snapshot(), []);
	assert(
		operation.retryAcquisition() === first,
		"recovery must join a preparation that has not returned its wrapper",
	);
	const refused = Promise.allSettled([first]);
	const closing = operation.close();
	preparing.resolve({
		submit() {
			submissions++;
			return Promise.resolve();
		},
		free() {
			freed++;
		},
	});
	await closing;
	assertEquals((await refused)[0].status, "rejected");
	assertEquals(submissions, 0, "shutdown cannot submit a late acquisition");
	assertEquals(freed, 2);
});

for (
	const notice of [{ kind: "handRoom", label: "Room" }, {
		kind: "handArchive",
		directory: "dir",
		scope: "room",
		conversation: "garden",
	}]
) {
	Deno.test(`managed ${notice.kind} arrival retry after commitment keeps the original incoming acquisition`, async () => {
		const accepted = snapshot();
		accepted.intent.conversations.push({
			kind: "direct",
			id: "dm",
			directory: "dir",
			peer: "peer",
			access: null,
			closed: false,
			draft: "",
		});
		let preparations = 0;
		let submissions = 0;
		let failRefresh = false;
		const session = viewer({
			snapshot: () =>
				failRefresh
					? Promise.reject(new Error("projection unavailable after commit"))
					: Promise.resolve(accepted),
		});
		await session.refresh();
		const page = {
			cursor: "original-cursor",
			event: {
				target: { kind: "direct", id: "dm" },
				notice,
				authority: {
					prepareAcquisition: (
						_revision: string,
						destination: string,
						releases: string,
						intent: string,
						source: string,
					) => {
						assertEquals(
							JSON.parse(destination).role,
							notice.kind === "handRoom" ? "roomAccess" : "archiveAccess",
						);
						assertEquals(JSON.parse(source).role, "sessionAccess");
						assertEquals(JSON.parse(releases), []);
						preparations++;
						return Promise.resolve({
							submit() {
								submissions++;
								accepted.intent = JSON.parse(intent);
								failRefresh = true;
								return Promise.resolve("committed");
							},
							free() {},
						});
					},
				},
			},
		} as unknown as ActivityPage;
		assertEquals((await Promise.allSettled([session.actions.receive(page)]))[0].status, "rejected");
		failRefresh = false;
		await session.actions.receive(page);
		assertEquals(preparations, 1);
		assertEquals(submissions, 1);
		assertEquals(
			notice.kind === "handRoom" ? accepted.intent.invitations.length : accepted.intent.archiveShares?.length,
			1,
		);
		await session.close();
	});
}

Deno.test("managed acquisition refusal wakes recovery and retry retires the original wrapper", async () => {
	let fail = true;
	let freed = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareDirectory: () =>
			Promise.resolve({
				submit: () =>
					fail ? Promise.reject(new Error("missing acknowledgement")) : Promise.resolve("committed"),
				free: () => {
					freed++;
				},
			}),
	});
	const notices: string[][] = [];
	const stop = session.subscribe(() => notices.push([...session.actions.recoverable]));
	try {
		const result = await Promise.allSettled([
			session.actions.directory("exact", "route", { kind: "exact", name: "ada" }, true),
		]);
		assertEquals(result[0].status, "rejected");
		assertEquals(notices, [[], ["directory:exact"]]);
		assertEquals(freed, 0);
		fail = false;
		await session.actions.recoverAcquisition("directory:exact");
		assertEquals(notices.slice(1, 3), [["directory:exact"], []]);
		assertEquals(freed, 1);
	} finally {
		stop();
		await session.close();
	}
});

Deno.test("typing reports one refusal per failed authority and preserves a newer target", async () => {
	const entered = deferred<void>();
	const release = deferred<void>();
	const sent: string[] = [];
	let reports = 0;
	const session = viewer({
		typingSender: (id: string) =>
			Promise.resolve({
				set: async () => {
					sent.push(id);
					if (id === "old") {
						entered.resolve();
						await release.promise;
						throw new Error("retired authority");
					}
				},
				free() {},
			}),
	});
	const first = session.typing.set("old", "seat", true).catch(() => reports++);
	await entered.promise;
	const repeats = Array.from({ length: 100 }, () => session.typing.set("old", "seat", true).catch(() => reports++));
	const newer = session.typing.set("new", "seat", true);
	release.resolve();
	await Promise.all([first, newer, ...repeats]);
	await session.typing.set("old", "seat", true);
	assertEquals([sent, reports], [["old", "new"], 1]);
	await session.close();
});

Deno.test("shared reads enforce capacity, drain before retirement and reject new work", async () => {
	const session = viewer({});
	const held = deferred<void>();
	let calls = 0;
	const read = (key: string) =>
		session.reads.run(key, () => {
			calls++;
			return held.promise;
		});
	const first = read("same");
	assertEquals(read("same") === first, true);
	const tasks = [first, ...Array.from({ length: 7 }, (_, index) => read(String(index)))];
	const [full] = await Promise.allSettled([read("overflow")]);
	assertEquals([full.status, calls, session.reads.active], ["rejected", 8, 8]);
	let closed = false;
	const closing = session.close().then(() => closed = true);
	await Promise.resolve();
	assertEquals(closed, false);
	held.resolve();
	await Promise.all(tasks);
	await closing;
	assertEquals(session.reads.active, 0);
	assertEquals((await Promise.allSettled([read("after-close")]))[0].status, "rejected");
});
