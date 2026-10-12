// Recompose only refused workspace deltas around the original committed receipt.
import { assert, assertEquals } from "../assert.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { ManagedOperation, ResultAcquisitionError } from "../../web/ui/session/managed/operation.ts";
import { completeResult } from "../../web/ui/session/managed/completion.ts";
import { readDirectReceipt } from "../../web/ui/session/managed/direct_receipt.ts";
import { CompletedLine } from "../../web/ui/session/managed/completed_line.ts";
import type { BridgeForm } from "../../lib/bridge/form.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";

for (
	const original of [
		["creation", "1", "openManagedRoom", ["directory", "garden"]],
		["creation", 1, "openManagedRoom"],
		["creation", 1, "openManagedRoom", "directory"],
		null,
		{},
		{ bridge: null },
		{ upload: "post" },
	]
) {
	Deno.test(`malformed retained intent refuses completion: ${JSON.stringify(original)}`, async () => {
		const receipt = { room: "returned-room", control: "returned-control" };
		const operation = new ManagedOperation("creation", {
			result: () => Promise.resolve(receipt),
			adopted: () => Promise.resolve(false),
			originalIntent: () => original,
			free() {},
		} as unknown as RoomsManagedCommand);
		const session = viewer({ snapshot: () => Promise.resolve(snapshot()) });
		try {
			const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
			assert(outcome.status === "rejected", "a malformed intent must not complete as a bridge receipt");
			assert(
				outcome.reason instanceof ResultAcquisitionError,
				"a committed receipt must retain acquisition recovery",
			);
			assertEquals(outcome.reason.result, receipt);
			assertEquals(operation.acquired, false);
		} finally {
			await operation.close();
			await session.close();
		}
	});
}

for (const upload of ["post", { refile: 7 }]) {
	Deno.test(`canonical upload intent completes its original line receipt: ${JSON.stringify(upload)}`, async () => {
		const current = snapshot();
		current.intent.conversations.push({
			kind: "room",
			id: "room",
			directory: "directory",
			name: "garden",
			access: null,
			control: null,
			reconnect: "requested",
			standing: null,
			draft: "later draft",
		});
		const result = { id: 7, line: "returned-line", history: null };
		let acquisitions = 0;
		const operation = new ManagedOperation("upload", {
			result: () => Promise.resolve(result),
			adopted: () => Promise.resolve(false),
			originalIntent: () => ({
				upload,
				operation: "upload",
				base: 1,
				conversation: "room",
				caption: "caption",
				previews: "[]",
				keep: [],
				files: [{ name: "example.txt", mime: "text/plain", size: 4, width: 0, height: 0 }],
			}),
			prepareResultAcquisition: (_revision: string, mappings: string) => {
				const [mapping] = JSON.parse(mappings);
				assertEquals(mapping[0], { role: "line", key: "returned-line" });
				acquisitions++;
				return Promise.resolve({ submit: () => Promise.resolve("committed"), free() {} });
			},
			free() {},
		} as unknown as RoomsManagedCommand);
		const session = viewer({ snapshot: () => Promise.resolve(current) });
		try {
			const completed = await completeResult(session, operation);
			assert(completed instanceof CompletedLine, "upload completion carries line custody");
			assert(completed.result === result, "completion borrows the original receipt");
			assertEquals(acquisitions, 1);
		} finally {
			await operation.close();
			await session.close();
		}
	});
}

Deno.test("canonical bridge intent completes without acquiring conversation custody", async () => {
	const result = { applied: true };
	const operation = new ManagedOperation("bridge", {
		result: () => Promise.resolve(result),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ({
			bridge: {
				declaration: {
					scope: "example",
					title: "Example bridge",
					said: "Ready",
					fields: [],
					actions: [{
						id: "apply",
						label: "Apply",
						busyLabel: "Applying",
						tone: "primary",
						remembered: false,
					}],
				} satisfies BridgeForm,
				action: "apply",
				answers: {},
			},
			operation: "bridge",
			base: 1,
			room: "room",
			seat: "seat",
			access: null,
			credentials: null,
			reapply: null,
		}),
		prepareResultAcquisition: () => {
			throw new Error("bridge completion has no workspace result to acquire");
		},
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({ snapshot: () => Promise.resolve(snapshot()) });
	try {
		assert(await completeResult(session, operation) === result, "bridge completion borrows its original result");
		assertEquals(operation.acquired, false);
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("direct receipt validation preserves the original variant without copying", () => {
	for (const receipt of [{ status: "pending" }, { status: "ready", inbox: "returned-route" }]) {
		assert(readDirectReceipt(receipt) === receipt, "validation must borrow the original receipt");
	}
});

for (const receipt of [{ status: "ready" }, { status: "ready", inbox: 1 }, { status: "unknown" }]) {
	Deno.test(`malformed direct receipt retains recovery before custody moves: ${JSON.stringify(receipt)}`, async () => {
		const operation = new ManagedOperation("direct", {
			result: () => Promise.resolve(receipt),
			adopted: () => Promise.resolve(false),
			originalIntent: () => ["direct", 1, "startDirect", ["directory", "bo", "registration", "opening"]],
			free() {},
		} as unknown as RoomsManagedCommand);
		const session = viewer({ snapshot: () => Promise.resolve(snapshot()) });
		try {
			const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
			assert(outcome.status === "rejected", "an invalid direct variant must not acquire custody");
			assert(
				outcome.reason instanceof ResultAcquisitionError,
				"the exact committed receipt must remain recoverable",
			);
			assertEquals(outcome.reason.result, receipt);
			assertEquals(operation.acquired, false);
		} finally {
			await operation.close();
			await session.close();
		}
	});
}

for (const held of [false, true]) {
	Deno.test(`operator moderator issuance retires its receipt with ${held ? "colliding display labels" : "no joined room"}`, async () => {
		const current = snapshot();
		if (held) {
			for (const id of ["first-room", "second-room"]) {
				current.intent.conversations.push({
					kind: "room",
					id,
					directory: id,
					name: "same label",
					source: `${id}-source`,
					access: `${id}-access`,
					control: null,
					reconnect: "requested",
					standing: null,
					draft: "kept",
				});
			}
		}
		const original = structuredClone(current.intent);
		let acquired = false;
		const operation = new ManagedOperation("moderator", {
			result: () => Promise.resolve({ name: "durable-directory-name", steward: "returned-moderator" }),
			adopted: () => Promise.resolve(acquired),
			originalIntent:
				() => ["moderator", 1, "operator", ["operator-key", "giveModerator", "durable-directory-name"]],
			prepareResultAcquisition: (_revision: string, mappings: string, releases: string, intent: string) => {
				assertEquals(JSON.parse(mappings), []);
				assertEquals(JSON.parse(releases), []);
				assertEquals(JSON.parse(intent), original);
				return Promise.resolve({
					submit: () => {
						acquired = true;
						return Promise.resolve("committed");
					},
					free() {},
				});
			},
			free() {},
		} as unknown as RoomsManagedCommand);
		const session = viewer({ snapshot: () => Promise.resolve(current) });
		try {
			await completeResult(session, operation);
			assert(acquired, "the returned occurrence is adopted before the local command finishes");
			assertEquals(current.intent, original);
		} finally {
			await operation.close();
			await session.close();
		}
	});
}

Deno.test("room link adoption replaces its entrance while retaining the exact public identity and seat", async () => {
	const current = snapshot();
	current.intent.conversations.push({
		kind: "room",
		id: "room",
		directory: "directory",
		name: "bridge",
		source: "source",
		access: null,
		publicEntry: { access: "directory-access" },
		publication: "exact-publication",
		seat: "original-seat",
		control: null,
		reconnect: "requested",
		standing: null,
		draft: "kept draft",
	});
	const operation = new ManagedOperation("link", {
		result: () => Promise.resolve({ room: "original-result" }),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["link", 1, "ensureRoomLink", ["room"]],
		prepareResultAcquisition: (_revision: string, _mappings: string, _releases: string, intent: string) =>
			Promise.resolve({
				submit: () => {
					current.intent = JSON.parse(intent);
					return Promise.resolve("committed");
				},
				free() {},
			}),
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	try {
		await completeResult(session, operation);
		const row = current.intent.conversations[0];
		assert(row.kind === "room", "room adoption");
		assert(row.access != null, "the committed receipt installs exact link custody");
		assertEquals([row.publicEntry, row.accepted], [undefined, undefined]);
		assertEquals([row.publication, row.seat, row.source, row.draft], [
			"exact-publication",
			"original-seat",
			"source",
			"kept draft",
		]);
		assertEquals(current.intent.conversations.length, 1);
	} finally {
		await operation.close();
		await session.close();
	}
});

for (const change of ["unrelated", "registration"] as const) {
	Deno.test(`outgoing direct result retains registration through ${change} acquisition conflict`, async () => {
		const current = snapshot();
		current.intent.directories.push({
			id: "directory",
			access: "access",
			source: "source",
			name: "name",
			inbox: "callback",
			home: true,
			nick: "ada",
			nickAllocation: "exact",
			standing: null,
		});
		let preparations = 0;
		const operation = new ManagedOperation("direct", {
			result: () => Promise.resolve({ status: "ready", inbox: "result" }),
			adopted: () => Promise.resolve(false),
			originalIntent: () => ["direct", 1, "startDirect", ["directory", "bob", "peer-registration", "opening"]],
			prepareResultAcquisition: (...args: string[]) => {
				preparations++;
				return Promise.resolve({
					submit: () => {
						if (preparations === 1) {
							current.revision = "2";
							current.intent.standing = "away";
							if (change === "registration") current.intent.directories[0].name = "replacement-name";
							return Promise.resolve("conflict");
						}
						current.intent = JSON.parse(args[3]);
						return Promise.resolve("committed");
					},
					free() {},
				});
			},
			free() {},
		} as unknown as RoomsManagedCommand);
		const session = viewer({ snapshot: () => Promise.resolve(current) });
		try {
			const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
			assertEquals(outcome.status, change === "unrelated" ? "fulfilled" : "rejected");
			assertEquals(preparations, change === "unrelated" ? 2 : 1);
			if (change === "unrelated") {
				const row = current.intent.conversations[0];
				assert(row.kind === "direct", "adoption creates the exact direct conversation");
				assertEquals(row.introduction, {
					access: "access",
					name: "name",
					callback: "callback",
					registration: "peer-registration",
					opening: "opening",
				});
				assertEquals(current.intent.standing, "away");
			}
		} finally {
			await operation.close();
			await session.close();
		}
	});
}

// A pending introduction is a known protocol answer (`{"status":"pending"}`,
// no inbox). It completes with the raw receipt and installs no custody.
Deno.test("pending direct result completes without custody acquisition", async () => {
	const current = snapshot();
	const result = { status: "pending" };
	const operation = new ManagedOperation("direct", {
		result: () => Promise.resolve(result),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["direct", 1, "startDirect", ["directory", "bob", "peer-registration", "opening"]],
		prepareResultAcquisition: () => {
			throw new Error("a pending introduction installs no custody");
		},
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	try {
		assertEquals(await completeResult(session, operation), result);
	} finally {
		await operation.close();
		await session.close();
	}
});

for (const first of ["conflict", "uncertain", "replaced"]) {
	Deno.test(`committed room result ${first} keeps its original receipt and selections`, async () => {
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
		const preparations: string[][] = [];
		let submissions = 0;
		let candidatesFreed = 0;
		let receiptsFreed = 0;
		let intentsDecoded = 0;
		const result = { room: "original-room", control: "original-control" };
		const operation = new ManagedOperation("creation", {
			result: () => Promise.resolve(result),
			adopted: () => Promise.resolve(false),
			originalIntent: () => {
				intentsDecoded++;
				return ["creation", 1, "openManagedRoom", ["directory", "garden"]];
			},
			prepareCreatedRoomAcquisition: (...args: string[]) => {
				const index = preparations.length;
				preparations.push(args);
				return Promise.resolve({
					submit: () => {
						if (index === 0) {
							if (first === "uncertain" && submissions++ === 0) {
								return Promise.reject(new Error("lost reply"));
							}
							current.revision = "2";
							current.intent.standing = "unrelated edit";
							if (first === "replaced") current.intent.directories[0].access = "replacement-access";
							return Promise.resolve("conflict");
						}
						current.revision = "3";
						current.intent = JSON.parse(args[3]);
						return Promise.resolve("committed");
					},
					free: () => candidatesFreed++,
				});
			},
			free: () => receiptsFreed++,
		} as unknown as RoomsManagedCommand);
		const session = viewer({ snapshot: () => Promise.resolve(current) });
		try {
			const completing = completeResult(session, operation);
			assert(completing === completeResult(session, operation), "concurrent completion shares one owner");
			const outcome = await Promise.allSettled([completing]);
			if (first === "uncertain") {
				assertEquals(outcome[0].status, "rejected");
				assertEquals(preparations.length, 1);
				assertEquals(candidatesFreed, 0, "uncertainty retains exact replay");
				assertEquals((await Promise.allSettled([operation.retryAcquisition()]))[0].status, "rejected");
				await completeResult(session, operation);
			} else assertEquals(outcome[0].status, first === "conflict" ? "fulfilled" : "rejected");
			assertEquals(receiptsFreed, 0, "no retry releases or replaces the committed receipt");
			assertEquals(
				intentsDecoded,
				first === "uncertain" ? 2 : 1,
				"decode once per completion, not per conflict retry",
			);
			assertEquals(preparations.length, first === "replaced" ? 1 : 2);
			if (first !== "replaced") {
				assertEquals(preparations[1][0], "2");
				assertEquals(
					preparations[1][1],
					preparations[0][1],
					"exact result and destination coordinates survive",
				);
				assertEquals(preparations[1][4], preparations[0][4], "original worker source coordinate survives");
				assertEquals(current.intent.standing, "unrelated edit");
				assertEquals(current.intent.conversations.length, 1);
				assert(operation.acquired, "original receipt result was adopted");
			}
			assertEquals(candidatesFreed, preparations.length);
		} finally {
			await operation.close();
			await session.close();
		}
		assertEquals(receiptsFreed, 1);
	});
}

Deno.test("viewer result completion and recovery share adoption and release the receipt once", async () => {
	const current = snapshot();
	current.intent.directories.push({
		id: "directory",
		access: "access",
		home: true,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	const started = deferred<void>();
	const release = deferred<void>();
	let commands = 0;
	let candidates = 0;
	let receipts = 0;
	const request = {
		submit: () => {
			commands++;
			return Promise.resolve("pending");
		},
		status: () => Promise.resolve("committed"),
		result: () => Promise.resolve({ room: "original-room", control: "original-control" }),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["creation", 1, "openManagedRoom", ["directory", "garden"]],
		prepareCreatedRoomAcquisition: (_revision: string, _mappings: string, _releases: string, intent: string) =>
			Promise.resolve({
				submit: async () => {
					started.resolve();
					await release.promise;
					current.intent = JSON.parse(intent);
					current.revision = "2";
					return "committed";
				},
				free: () => candidates++,
			}),
		free: () => receipts++,
	} as unknown as RoomsManagedCommand;
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	try {
		const operation = await session.perform("creation", () => Promise.resolve(request));
		const completing = session.completeResult(operation);
		await started.promise;
		assert(
			completing === session.completeResult(operation),
			"viewer shares the entire completion including finish",
		);
		const recovering = session.completeOperation("creation");
		release.resolve();
		await completing;
		assertEquals(await recovering, true);
		assertEquals([commands, candidates, receipts], [1, 1, 1]);
		assertEquals(session.pending, []);
	} finally {
		await session.close();
	}
});

Deno.test("operation close drains result preparation before releasing Wasm wrappers", async () => {
	const current = snapshot();
	current.intent.directories.push({
		id: "directory",
		access: "access",
		home: true,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	const started = deferred<void>();
	const prepared = deferred<{ submit(): Promise<string>; free(): void }>();
	let receipts = 0;
	let candidates = 0;
	let submissions = 0;
	const operation = new ManagedOperation("creation", {
		result: () => Promise.resolve({ room: "original-room", control: "original-control" }),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["creation", 1, "openManagedRoom", ["directory", "garden"]],
		prepareCreatedRoomAcquisition: () => {
			started.resolve();
			return prepared.promise;
		},
		free: () => receipts++,
	} as unknown as RoomsManagedCommand);
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	try {
		const completing = completeResult(session, operation);
		await started.promise;
		const closing = operation.close();
		assertEquals(receipts, 0);
		prepared.resolve({
			submit: () => {
				submissions++;
				return Promise.resolve("committed");
			},
			free: () => candidates++,
		});
		assertEquals((await Promise.allSettled([completing]))[0].status, "rejected");
		await closing;
		assertEquals([receipts, candidates, submissions], [1, 1, 0]);
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("direct receipt adoption preserves sender provenance and a later identical draft", async () => {
	const current = snapshot();
	current.intent.conversations.push({
		kind: "direct",
		id: "direct",
		directory: "directory",
		peer: "bob",
		access: "access",
		source: "source",
		closed: false,
		draft: "hello",
		lines: [{ id: 7, handle: "sender-origin" }],
	});
	let mappings: unknown;
	let releases: unknown;
	const operation = new ManagedOperation("send", {
		result: () => Promise.resolve({ id: 7, line: "receipt-line" }),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["send", 1, "say", ["direct", "hello"]],
		prepareResultAcquisition: (_revision: string, imports: string, dropped: string, intent: string) => {
			mappings = JSON.parse(imports);
			releases = JSON.parse(dropped);
			return Promise.resolve({
				submit: () => {
					current.intent = JSON.parse(intent);
					return Promise.resolve("committed");
				},
				free() {},
			});
		},
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	try {
		await completeResult(session, operation);
		assertEquals(mappings, [[{ role: "line", key: "receipt-line" }, { role: "line", key: "sender-origin" }]]);
		assertEquals(releases, []);
		assertEquals(current.intent.conversations[0].lines, [{ id: 7, handle: "sender-origin" }]);
		assertEquals(current.intent.conversations[0].draft, "hello");
	} finally {
		await operation.close();
		await session.close();
	}
});
