// A proved conflict releases the candidate. Uncertainty retains exact replay.
import { assert, assertEquals } from "../assert.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { AcquisitionConflict } from "../../web/ui/session/managed/acquisition.ts";
import { ManagedOperation } from "../../web/ui/session/managed/operation.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import { ConversationOpening } from "../../web/ui/session/managed/openings.ts";
import { OPEN_ROOM_POLICY } from "../../lib/room/policy.ts";

Deno.test("a cancelled uncertain room admission recovers and leaves its exact membership before a fresh join", async () => {
	const current = snapshot();
	current.intent.directories.push({
		id: "dir",
		access: "access",
		home: true,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	let prepared = 0, submitted = 0;
	const departed: string[] = [];
	const refusal = new Error("admission reply lost");
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		preparePublicRoom: (_revision: string, raw: string) => {
			prepared++;
			const room = JSON.parse(raw);
			return Promise.resolve({
				submit: () => {
					if (++submitted === 1) return Promise.reject(refusal);
					current.intent.conversations.push({
						kind: "room",
						...room,
						access: null,
						control: null,
						reconnect: "requested",
						standing: null,
						draft: "",
					});
					return Promise.resolve("committed");
				},
				free() {},
			});
		},
	});
	const cancel = new AbortController();
	session.command = (_name, args = []) => {
		departed.push(args[0]);
		current.intent.conversations = current.intent.conversations.filter((row) => row.id !== args[0]);
		return Promise.resolve({} as ManagedOperation);
	};
	session.completeResult = () => Promise.resolve();
	try {
		const [outcome] = await Promise.allSettled([
			session.openings.run(
				(opening) => session.actions.publicRoom("dir", "garden", "publication", opening),
				null,
				cancel.signal,
			),
		]);
		assert(
			outcome.status === "rejected" && outcome.reason === refusal,
			"the original refusal belongs to this attempt",
		);
		cancel.abort();
		const fresh = await session.actions.publicRoom("dir", "garden", "publication");
		assertEquals([prepared, submitted, departed.length], [2, 3, 1]);
		assert(fresh !== departed[0], "recovery cannot hand a departed conversation to a fresh join");
		assertEquals(current.intent.conversations.map((row) => row.id), [fresh]);
		assertEquals(session.actions.pending, []);
	} finally {
		await session.close();
	}
});

Deno.test("cancelling initial directory preparation frees the request before admission", async () => {
	const entered = deferred<void>(), release = deferred<void>();
	let submitted = 0, freed = 0;
	const session = viewer({
		prepareDirectory: async () => {
			entered.resolve();
			await release.promise;
			return {
				submit: () => {
					submitted++;
					return Promise.resolve("committed");
				},
				free: () => freed++,
			};
		},
	});
	const cancel = new AbortController();
	try {
		const result = Promise.allSettled([
			session.actions.directory(
				"directory",
				"127.0.0.1:1234",
				{ kind: "exact", name: "ada" },
				true,
				cancel.signal,
			),
		]);
		await entered.promise;
		cancel.abort();
		release.resolve();
		const [outcome] = await result;
		assert(outcome.status === "rejected" && outcome.reason.name === "AbortError", "cancellation refuses admission");
		assertEquals(submitted, 0);
		assertEquals(freed, 1);
		assertEquals(session.actions.pending, []);
	} finally {
		release.resolve();
		await session.close();
	}
});

Deno.test("a fresh directory press waits for cancelled preparation before acquiring", async () => {
	const entered = deferred<void>();
	const release = deferred<void>();
	const cancelled = new AbortController();
	let prepared = 0;
	let submitted = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareDirectory: async () => {
			if (++prepared === 1) {
				entered.resolve();
				await release.promise;
			}
			return {
				submit: () => {
					submitted++;
					return Promise.resolve("committed");
				},
				free() {},
			};
		},
	});
	try {
		const old = Promise.allSettled([
			session.actions.directory(
				"directory",
				"127.0.0.1:1234",
				{ kind: "exact", name: "ada" },
				true,
				cancelled.signal,
			),
		]);
		await entered.promise;
		cancelled.abort();
		const next = session.actions.directory("directory", "127.0.0.1:1234", { kind: "exact", name: "ada" }, true);
		const result = Promise.allSettled([next]);
		release.resolve();
		assertEquals((await old)[0].status, "rejected");
		assertEquals((await result)[0].status, "fulfilled", "a fresh press must not inherit the old cancellation");
		assertEquals([prepared, submitted], [2, 1]);
	} finally {
		release.resolve();
		await session.close();
	}
});

Deno.test("cancelling after a proved directory conflict stops re-admission and permits a fresh press", async () => {
	const entered = deferred<void>(), release = deferred<void>();
	const cancel = new AbortController();
	let prepared = 0, submitted = 0, freed = 0;
	const request = (first: boolean) => ({
		submit: () => {
			submitted++;
			return Promise.resolve(first ? "conflict" : "committed");
		},
		reprepare: async () => {
			entered.resolve();
			await release.promise;
			return request(false);
		},
		free: () => freed++,
	});
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareDirectory: () => Promise.resolve(request(++prepared === 1)),
	});
	try {
		const old = Promise.allSettled([
			session.actions.directory("dir", "route", { kind: "exact", name: "ada" }, false, cancel.signal),
		]);
		await entered.promise;
		cancel.abort();
		const fresh = Promise.allSettled([
			session.actions.directory("dir", "route", { kind: "exact", name: "ada" }, false),
		]);
		release.resolve();
		const [outcome] = await old;
		assert(
			outcome.status === "rejected" && outcome.reason.name === "AbortError",
			"proved non-admission belongs to the cancelled attempt",
		);
		assertEquals((await fresh)[0].status, "fulfilled");
		assertEquals([prepared, submitted, freed], [2, 2, 3]);
	} finally {
		release.resolve();
		await session.close();
	}
});

Deno.test("repeated public room acquisition shares one admitted request", async () => {
	const current = snapshot();
	current.intent.directories.push({
		id: "directory",
		access: "exact-access",
		source: "exact-source",
		home: true,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	let preparations = 0;
	let freed = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		preparePublicRoom: (_revision: string, selection: string) => {
			preparations++;
			const selected = JSON.parse(selection);
			return Promise.resolve({
				submit: () => {
					if (current.intent.conversations.length !== 0) return Promise.resolve("conflict");
					current.intent.conversations.push({
						kind: "room",
						id: selected.id,
						directory: selected.directory,
						name: selected.name,
						publication: selected.publication,
						publicEntry: { access: "exact-access" },
						access: null,
						control: null,
						reconnect: "requested",
						standing: null,
						draft: "",
					});
					current.revision = "2";
					return Promise.resolve("committed");
				},
				free: () => freed++,
			});
		},
	});
	try {
		const ids = await Promise.all([
			session.actions.publicRoom("directory", "garden", "exact-publication"),
			session.actions.publicRoom("directory", "garden", "exact-publication"),
		]);
		assertEquals(ids[0], ids[1]);
		assertEquals(current.intent.conversations.length, 1);
		assertEquals(preparations, 1, "both entry points share the original acquisition");
		assertEquals(freed, 1);
		assertEquals(session.actions.pending, []);
	} finally {
		await session.close();
	}
});

for (const refusal of ["conflict", "uncertain", "replaced"]) {
	Deno.test(`managed room creation ${refusal} preserves exact admission authority`, async () => {
		const current = snapshot();
		current.intent.directories.push({
			id: "directory",
			access: "original-access",
			source: "original-source",
			home: true,
			nick: "ada",
			nickAllocation: "exact",
			standing: null,
		});
		const preparations: unknown[][] = [];
		let submissions = 0;
		let freed = 0;
		const session = viewer({
			snapshot: () => Promise.resolve(current),
			prepareCommand: (operation: string, revision: string, name: string, args: string[]) => {
				preparations.push([operation, revision, name, args]);
				return Promise.resolve({
					submit: () => {
						if (submissions++ > 0) return Promise.resolve("pending");
						if (refusal === "uncertain") return Promise.reject(new Error("lost admission"));
						current.revision = "2";
						if (refusal === "replaced") current.intent.directories[0].access = "replacement";
						return Promise.resolve("conflict");
					},
					status: () => Promise.resolve("committed"),
					free: () => freed++,
				});
			},
		});
		session.completeResult = () => Promise.resolve(undefined);
		try {
			const result = await Promise.allSettled([
				session.actions.createRoom("directory", "garden", OPEN_ROOM_POLICY),
			]);
			assertEquals(result[0].status, refusal === "conflict" ? "fulfilled" : "rejected");
			assertEquals(preparations.length, refusal === "conflict" ? 2 : 1);
			if (refusal === "conflict") {
				assertEquals(
					preparations[1][0],
					preparations[0][0],
					"conflict retains the original operation identity",
				);
				assertEquals(preparations[1][3], preparations[0][3], "conflict retains the exact target and arguments");
				assertEquals(preparations[1][1], "2");
			}
			assertEquals(freed, refusal === "uncertain" ? 0 : 1, "uncertainty retains its request");
		} finally {
			await session.close();
		}
	});
}

Deno.test("managed custody conflict releases its candidate and permits a reviewed preparation", async () => {
	let preparations = 0;
	let freed = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareAcquisition: () => {
			const outcome = preparations++ === 0 ? "conflict" : "committed";
			return Promise.resolve({ submit: () => Promise.resolve(outcome), free: () => freed++ });
		},
	});
	try {
		const first = await Promise.allSettled([
			session.actions.replace(snapshot()),
		]);
		assert(
			first[0].status === "rejected" && first[0].reason instanceof AcquisitionConflict,
			"a conflict is definite refusal",
		);
		assertEquals(session.actions.pending, []);
		assertEquals(freed, 1);
		await session.actions.replace(snapshot());
		assertEquals(preparations, 2);
		assertEquals(freed, 2);
	} finally {
		await session.close();
	}
});

for (const initial of ["conflict", "uncertain"]) {
	Deno.test(`directory ${initial} keeps acquired authority through conflict recovery`, async () => {
		let fetched = 0;
		let submitted = 0;
		let reprepared = 0;
		const freed: string[] = [];
		const candidate = (id: string) => ({
			submit: () => {
				if (id === "replacement") return Promise.resolve("committed");
				if (initial === "uncertain" && submitted++ === 0) return Promise.reject(new Error("lost reply"));
				return Promise.resolve("conflict");
			},
			reprepare: () => {
				reprepared++;
				assertEquals(freed, [], "original stays held through replacement admission");
				return Promise.resolve(candidate("replacement"));
			},
			free: () => freed.push(id),
		});
		const session = viewer({
			snapshot: () => Promise.resolve(snapshot()),
			prepareDirectory: () => {
				fetched++;
				return Promise.resolve(candidate("original"));
			},
		});
		try {
			const result = await Promise.allSettled([
				session.actions.directory("original", "route", { kind: "exact", name: "ada" }, true),
			]);
			if (initial === "uncertain") {
				assertEquals(result[0].status, "rejected");
				assertEquals(reprepared, 0);
				assertEquals(freed, []);
				assertEquals(session.actions.pending, ["directory:original"]);
				await session.actions.recoverAcquisition("directory:original");
			} else assertEquals(result[0].status, "fulfilled");
			assertEquals(fetched, 1, "recovery never fetches the display route again");
			assertEquals(reprepared, 1);
			assertEquals(freed, ["original", "replacement"]);
			assertEquals(session.actions.pending, []);
		} finally {
			await session.close();
		}
	});
}

for (const first of ["conflict", "uncertain"]) {
	Deno.test(`managed result ${first} preserves the committed receipt and exact recovery ownership`, async () => {
		let preparations = 0;
		let attempts = 0;
		let candidatesFreed = 0;
		let receiptsFreed = 0;
		const operation = new ManagedOperation("original", {
			prepareResultAcquisition: () => {
				preparations++;
				return Promise.resolve({
					submit: () => {
						if (attempts++ === 0) {
							return first === "conflict"
								? Promise.resolve("conflict")
								: Promise.reject(new Error("lost acknowledgement"));
						}
						return Promise.resolve("committed");
					},
					free: () => candidatesFreed++,
				});
			},
			free: () => receiptsFreed++,
		} as unknown as RoomsManagedCommand);
		try {
			const result = await Promise.allSettled([operation.acquire(snapshot(), [])]);
			assertEquals(result[0].status, "rejected");
			assertEquals(receiptsFreed, 0, "the upstream receipt remains held");
			assert(!operation.acquired, "failed acquisition cannot report committed access");
			if (first === "conflict") {
				assert(!operation.acquiring, "a proved conflict releases the stale candidate");
				assertEquals(candidatesFreed, 1);
				await operation.acquire({ ...snapshot(), revision: "2" }, []);
				assertEquals(preparations, 2);
			} else {
				assert(operation.acquiring, "uncertainty retains exact candidate custody");
				assertEquals(candidatesFreed, 0);
				await operation.retryAcquisition();
				assertEquals(preparations, 1);
			}
			assert(operation.acquired, "recovery confirms adoption of the original result");
			assertEquals(candidatesFreed, preparations);
		} finally {
			await operation.close();
		}
		assertEquals(receiptsFreed, 1);
	});
}

Deno.test("lost public-room acquisition reply retries the exact request and conversation", async () => {
	const current = snapshot();
	current.intent.directories.push({
		id: "dir",
		access: "access",
		home: true,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	let prepared = 0;
	let submitted = 0;
	let adopted = "";
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		preparePublicRoom: (_revision: string, raw: string) => {
			prepared++;
			adopted = JSON.parse(raw).id;
			return Promise.resolve({
				submit: () =>
					++submitted === 1 ? Promise.reject(new Error("reply lost")) : Promise.resolve("committed"),
				free() {},
			});
		},
	});
	await Promise.allSettled([session.actions.publicRoom("dir", "garden", "publication")]);
	assertEquals(session.actions.recoverable.length, 1);
	const id = await session.actions.publicRoom("dir", "garden", "publication");
	assertEquals([prepared, submitted, id], [1, 2, adopted]);
	assertEquals(session.actions.pending, []);
	await session.close();
});

Deno.test("failed acquisition preparation has no retained decision even during notification", async () => {
	const session = viewer({ prepareDirectory: () => Promise.reject(new Error("not prepared")) });
	const decisions: string[][] = [];
	const stop = session.subscribe(() => decisions.push([...session.actions.recoverable]));
	await Promise.allSettled([session.actions.directory("dir", "route", { kind: "exact", name: "ada" }, false)]);
	assertEquals(decisions.every((ids) => ids.length === 0), true);
	stop();
	await session.close();
});

Deno.test("committed acquisition with a failed refresh retries only the refresh", async () => {
	let reads = 0, prepared = 0, submitted = 0, freed = 0;
	const session = viewer({
		snapshot: () => ++reads === 1 ? Promise.reject(new Error("refresh disconnected")) : Promise.resolve(snapshot()),
		prepareDirectory: () => {
			prepared++;
			return Promise.resolve({
				submit: () => {
					submitted++;
					return Promise.resolve("committed");
				},
				free: () => freed++,
			});
		},
	});
	const [result] = await Promise.allSettled([
		session.actions.directory("dir", "route", { kind: "exact", name: "ada" }, false),
	]);
	assertEquals(result.status, "rejected");
	assertEquals(session.actions.recoverable, ["directory:dir"]);
	assertEquals(session.actions.diagnostics[0].outcome, "committed");
	await session.actions.directory("dir", "route", { kind: "exact", name: "ada" }, false);
	assertEquals([prepared, submitted, freed, reads], [1, 1, 1, 2]);
	assertEquals(session.actions.pending, []);
	await session.close();
	assertEquals(session.resources, {
		effects: { effects: 0, workers: 0 },
		acquisitions: { acquisitions: 0, workers: 0, gestures: 0 },
		workers: 0,
		reads: 0,
		listeners: 0,
		waiters: 0,
		observation: false,
		activity: false,
	});
});

for (const timing of ["preparing", "committed"] as const) {
	Deno.test(`cancelling room creation while ${timing} stops admission or releases the acquired membership`, async () => {
		const current = snapshot();
		current.intent.directories.push({
			id: "directory",
			access: "access",
			source: "source",
			home: true,
			nick: "ada",
			nickAllocation: "exact",
			standing: null,
		});
		const entered = deferred<void>(), release = deferred<void>();
		const cancel = new AbortController();
		let submitted = 0, freed = 0;
		const left: string[][] = [];
		const session = viewer({
			snapshot: () => Promise.resolve(current),
			prepareCommand: (id: string, revision: string, name: string, args: string[]) => {
				entered.resolve();
				const request = {
					originalIntent: () => [id, Number(revision), name, args],
					submit: () => {
						if (name === "openManagedRoom") submitted++;
						return Promise.resolve("committed");
					},
					status: () => Promise.resolve("committed"),
					free: () => freed++,
				};
				return timing === "preparing" ? release.promise.then(() => request) : Promise.resolve(request);
			},
		});
		session.completeResult = async (command) => {
			if (timing === "committed") {
				entered.resolve();
				await release.promise;
			}
			if (timing === "committed" && !current.intent.conversations.some((row) => row.id === command.id)) {
				current.intent.conversations.push({
					kind: "room",
					id: command.id,
					directory: "directory",
					name: "garden",
					access: "entry",
					control: null,
					reconnect: "requested",
					standing: null,
					draft: "",
				});
			}
			session.finish(command);
		};
		const command = session.command.bind(session);
		session.command = (name, args, ...rest) => {
			if (name === "leaveConversation") left.push(args ?? []);
			return command(name, args, ...rest);
		};
		try {
			const result = Promise.allSettled([
				session.actions.createRoom(
					"directory",
					"garden",
					OPEN_ROOM_POLICY,
					new ConversationOpening(session, () => {}, cancel.signal),
				),
			]);
			await entered.promise;
			if (timing === "committed") { while (submitted === 0) await Promise.resolve(); }
			cancel.abort();
			const retry = session.actions.createRoom(
				"directory",
				"garden",
				OPEN_ROOM_POLICY,
				new ConversationOpening(session),
			);
			release.resolve();
			const [outcome] = await result;
			const next = await retry;
			assertEquals(submitted, timing === "preparing" ? 1 : 2);
			if (timing === "preparing") {
				assertEquals(outcome.status, "rejected");
				assertEquals(freed, 2);
				assertEquals(left, []);
			} else {
				assertEquals(outcome.status, "fulfilled");
				assertEquals(left.length, 1);
				if (outcome.status === "fulfilled") {
					assertEquals(left[0], [outcome.value]);
					assert(next !== outcome.value, "new join must acquire its own room");
				}
			}
		} finally {
			release.resolve();
			await session.close();
		}
	});
}
