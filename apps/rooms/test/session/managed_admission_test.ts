// One viewer prepares commands in order. Other viewers retain revision fences.
import { assert, assertEquals } from "../assert.ts";
import { ResultAcquisitionError } from "../../web/ui/session/managed/operation.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { initializeApplication } from "../support/application.ts";

await initializeApplication();

Deno.test("terminal observation wakes admission and releases its completed wrapper without resubmission", async () => {
	let status = "pending";
	let submissions = 0;
	const waiting = deferred<void>();
	const failure = "No relay answered a register socket";
	const received = deferred<string>();
	let freed = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: (id: string, revision: string, name: string, args: string[]) =>
			Promise.resolve({
				originalIntent: () => [id, Number(revision), name, args],
				submit: () => {
					submissions++;
					return Promise.resolve("pending");
				},
				status: () => {
					waiting.resolve();
					return Promise.resolve(status);
				},
				receive: () => received.promise,
				result: () => Promise.resolve({ observationFailure: failure }),
				free() {
					freed++;
				},
			}),
	});
	const outcome = Promise.allSettled([session.command("operations", ["original"], "failed")]);
	await waiting.promise;
	status = "unknown";
	received.resolve("unknown");
	const [result] = await outcome;
	assertEquals(result.status, "rejected");
	if (result.status === "rejected") assertEquals(result.reason.message, failure);
	assertEquals(submissions, 1);
	assertEquals(session.pending, []);
	assertEquals(freed, 1);
	await session.close();
});

Deno.test("managed commands prepare after the previous local admission", async () => {
	const current = snapshot();
	const entered = deferred<void>();
	const release = deferred<void>();
	const prepared: [string, string][] = [];
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		prepareCommand: (_id: string, revision: string, name: string) => {
			prepared.push([name, revision]);
			return Promise.resolve({
				originalIntent: () => null,
				submit: async () => {
					if (name === "first") {
						entered.resolve();
						await release.promise;
						current.revision = "2";
					}
					return "committed";
				},
				status: () => Promise.resolve("committed"),
				free() {},
			});
		},
	});
	await session.refresh();
	const first = session.command("first");
	await entered.promise;
	const second = session.command("second");
	for (let i = 0; i < 10; i++) await Promise.resolve();
	assertEquals(prepared, [["first", "1"]]);
	release.resolve();
	const commands = await Promise.all([first, second]);
	assertEquals(prepared, [["first", "1"], ["second", "2"]]);
	for (const command of commands) session.finish(command);
	await session.close();
});

Deno.test("a slow upstream effect holds back no later command", async () => {
	let upstream = "pending";
	const settled = deferred<string>();
	const prepared: string[] = [];
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: (_id: string, _revision: string, name: string) => {
			prepared.push(name);
			return Promise.resolve({
				originalIntent: () => null,
				submit: () => Promise.resolve("pending"),
				status: () => Promise.resolve(name === "slow" ? upstream : "committed"),
				receive: () => settled.promise,
				free() {},
			});
		},
	});
	const slow = session.command("slow");
	const quick = await session.command("quick");
	assertEquals(prepared, ["slow", "quick"]);
	session.finish(quick);
	upstream = "committed";
	settled.resolve("committed");
	await session.refresh();
	session.finish(await slow);
	await session.close();
});

Deno.test("receipt observation survives workspace wakes, renews finite reads and retains a refused command", async () => {
	const first = deferred<string>();
	const second = Promise.withResolvers<string>();
	const entered = [deferred<void>(), deferred<void>()];
	let reads = 0;
	const refusal = new Error("original source was paused");
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () =>
			Promise.resolve({
				submit: () => Promise.resolve("pending"),
				status: () => Promise.resolve("pending"),
				receive: () => {
					entered[reads].resolve();
					return (++reads === 1 ? first : second).promise;
				},
				free() {},
			}),
	});
	const outcome = Promise.allSettled([session.command("operations", [], "original")]);
	await entered[0].promise;
	for (let index = 0; index < 8; index++) await session.refresh();
	assertEquals(reads, 1);
	first.resolve("pending");
	await entered[1].promise;
	second.reject(refusal);
	const [result] = await outcome;
	assertEquals(result.status, "rejected");
	if (result.status === "rejected") assertEquals(result.reason, refusal);
	assertEquals(reads, 2);
	assertEquals(session.pending, ["original"]);
	await session.close();
});

Deno.test("repeated terminal observations leave admission capacity available", async () => {
	let submitted = 0;
	let freed = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () =>
			Promise.resolve({
				submit: () => {
					submitted++;
					return Promise.resolve("unknown");
				},
				status: () => Promise.resolve("unknown"),
				result: () => Promise.resolve({ observationFailure: "relay refused" }),
				free: () => freed++,
			}),
	});
	for (let index = 0; index < 16; index++) {
		const [result] = await Promise.allSettled([session.command("operations", [], `failure-${index}`)]);
		assertEquals(result.status, "rejected");
		if (result.status === "rejected") assertEquals(result.reason.message, "relay refused");
		assertEquals(session.pending, []);
	}
	assertEquals(submitted, 16);
	assertEquals(freed, 16);
	await session.close();
});

Deno.test("a refused diagnostic read preserves the original uncertain operation", async () => {
	const refusal = new Error("source was paused");
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () =>
			Promise.resolve({
				submit: () => Promise.resolve("unknown"),
				status: () => Promise.resolve("unknown"),
				result: () => Promise.reject(refusal),
				free() {},
			}),
	});
	const [result] = await Promise.allSettled([session.command("operations", [], "original")]);
	assertEquals(result.status, "rejected");
	if (result.status === "rejected") assertEquals(result.reason, refusal);
	assertEquals(session.pending, ["original"]);
	await session.close();
});

Deno.test("proved absence releases the original command wrapper", async () => {
	let freed = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () =>
			Promise.resolve({
				submit: () => Promise.resolve("unsent"),
				status: () => Promise.resolve("unsent"),
				free: () => freed++,
			}),
	});
	const [result] = await Promise.allSettled([session.command("operations", [], "absent")]);
	assertEquals(result.status, "rejected");
	assertEquals(session.pending, []);
	assertEquals(freed, 1);
	await session.close();
});

Deno.test("a refused local command releases its admission lane", async () => {
	let attempts = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () => {
			if (++attempts === 1) return Promise.reject(new Error("prepare refused"));
			return Promise.resolve({
				submit: () => Promise.resolve("committed"),
				status: () => Promise.resolve("committed"),
				free() {},
			});
		},
	});
	const [refused] = await Promise.allSettled([session.command("first")]);
	assertEquals(refused.status, "rejected");
	const command = await session.command("second");
	session.finish(command);
	await session.close();
});

for (const change of ["callback", "access", "source", "uncertain"] as const) {
	Deno.test(`room offer admission preserves the selected route across ${change}`, async () => {
		let current = snapshot();
		current.intent.conversations = [
			{
				kind: "room",
				id: "room",
				directory: "directory",
				source: "room-source",
				access: "room-access",
				name: "plans",
				control: null,
				reconnect: "requested",
				standing: null,
				draft: "",
			},
			{
				kind: "direct",
				id: "direct",
				directory: "directory",
				source: "direct-source",
				access: "direct-access",
				peer: "bo",
				closed: false,
				draft: "",
			},
		];
		const prepared: [string, string, string[]][] = [];
		let submissions = 0;
		let freed = 0;
		const session = viewer({
			snapshot: () => Promise.resolve(current),
			prepareCommand: (id: string, revision: string, name: string, args: string[]) => {
				prepared.push([id, revision, args]);
				return Promise.resolve({
					originalIntent: () => [id, Number(revision), name, args],
					submit: () => {
						if (++submissions > 1) return Promise.resolve("committed");
						if (change === "uncertain") return Promise.reject(new Error("acknowledgment lost"));
						current = structuredClone(current);
						current.revision = "2";
						const direct = current.intent.conversations[1];
						if (direct.kind !== "direct") throw new Error("expected direct selection");
						if (change === "callback") direct.inbox = "installed-callback";
						else direct[change] = "replacement";
						return Promise.resolve("conflict");
					},
					status: () => Promise.resolve("committed"),
					free: () => {
						freed++;
					},
				});
			},
		});
		try {
			const result = await Promise.allSettled([session.command("offerRoom", ["room", "direct"], "offer")]);
			assertEquals(result[0].status, change === "callback" ? "fulfilled" : "rejected");
			assertEquals(submissions, change === "callback" ? 2 : 1);
			assertEquals(
				prepared.map((row) => row[1]),
				change === "callback" ? ["1", "2"] : ["1"],
			);
			assertEquals(freed, change === "uncertain" ? 0 : 1);
			assertEquals(session.pending, change === "callback" || change === "uncertain" ? ["offer"] : []);
			if (result[0].status === "fulfilled") session.finish(result[0].value);
		} finally {
			await session.close();
		}
	});
}

Deno.test("equal command text does not reuse another gesture's uncertain receipt", async () => {
	const prepared: string[] = [];
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: (id: string, revision: string, name: string, args: string[]) => {
			prepared.push(id);
			const status = id === "original" ? "unknown" : "committed";
			return Promise.resolve({
				originalIntent: () => [id, Number(revision), name, args],
				submit: () => Promise.resolve(status),
				status: () => Promise.resolve(status),
				result: () => Promise.reject(new Error("original delivery remains uncertain")),
				free() {},
			});
		},
	});
	// Supply the retained observation so a wrong recovery is visible as the
	// wrong operation identity, rather than a missing fixture method.
	session.resume = (id) => Promise.resolve([...session.pendingOperations].find((pending) => pending.id === id)!);
	try {
		await Promise.allSettled([session.command("say", ["direct", "same text"], "original")]);
		assertEquals(session.pending, ["original"]);
		const second = await session.command("say", ["direct", "same text"], "next-gesture");
		assertEquals(second.id, "next-gesture");
		assertEquals(prepared, ["original", "next-gesture"]);
		session.finish(second);
		assertEquals(session.pending, ["original"]);
	} finally {
		await session.close();
	}
});

for (const stage of ["status", "refresh", "result"] as const) {
	Deno.test(`a ${stage} failure preserves exactly the commit evidence already observed`, async () => {
		let submitted = false;
		const reason = new Error("observation interrupted");
		const session = viewer({
			snapshot: () => submitted && stage === "refresh" ? Promise.reject(reason) : Promise.resolve(snapshot()),
		});
		const request = {
			submit: () => {
				submitted = true;
				return Promise.resolve("pending");
			},
			status: () => stage === "status" ? Promise.reject(reason) : Promise.resolve("committed"),
			result: () => Promise.reject(reason),
			originalIntent: () => ["known", 1, "say", ["room", "delivered"]],
			free() {},
		} as unknown as RoomsManagedCommand;
		try {
			const outcome = (await Promise.allSettled([(async () => {
				const operation = await session.perform("known", () => Promise.resolve(request));
				await session.completeResult(operation);
			})()]))[0];
			assert(outcome.status === "rejected", "the interrupted observation is reported");
			if (stage === "status") assert(outcome.reason === reason, "an unread status proves no commit");
			else {
				assert(outcome.reason instanceof ResultAcquisitionError, "observed commit survives later failure");
				assert(outcome.reason.cause === reason, "the interruption retains its cause");
			}
			assertEquals(session.pending, ["known"], "recovery retains the original operation");
		} finally {
			await session.close();
		}
	});
}

Deno.test("owned admission and settlement never publish a recovery decision", async () => {
	const admitted = deferred<void>();
	const settled = deferred<void>();
	let status = "pending";
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () =>
			Promise.resolve({
				submit: async () => {
					await admitted.promise;
					return "pending";
				},
				status: () => Promise.resolve(status),
				receive: () => settled.promise,
				free() {},
			}),
	});
	const decisions: string[][] = [];
	const stop = session.subscribe(() => decisions.push([...session.recoverable]));
	const pending = session.command("first", [], "owned");
	await session.refresh();
	admitted.resolve();
	for (let i = 0; i < 20; i++) await Promise.resolve();
	await session.refresh();
	assertEquals(session.recoverable, []);
	status = "committed";
	settled.resolve();
	const operation = await pending;
	assertEquals(decisions.every((ids) => ids.length === 0), true);
	session.finish(operation);
	stop();
	await session.close();
});

Deno.test("lost admission explicitly orphans only the retained operation", async () => {
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () =>
			Promise.resolve({
				submit: () => Promise.reject(new Error("reply lost")),
				free() {},
			}),
	});
	await Promise.allSettled([session.command("first", [], "retained")]);
	assertEquals(session.recoverable, ["retained"]);
	await session.close();
});

// TypeScript enforces the table against the generated verb inventory; this
// loop exercises the common owner for every declared policy as well.
import { GESTURES } from "../../web/ui/session/managed/gestures.ts";
for (const name of Object.keys(GESTURES)) {
	Deno.test(`${name}: owned admission never becomes a decision`, async () => {
		const reply = deferred<string>();
		const session = viewer({
			snapshot: () => Promise.resolve(snapshot()),
			prepareCommand: () =>
				Promise.resolve({
					submit: () => reply.promise,
					status: () => Promise.resolve("committed"),
					free() {},
				}),
		});
		const decisions: string[][] = [];
		const stop = session.subscribe(() => decisions.push([...session.recoverable]));
		const work = session.command(name, [], "owned");
		await session.refresh();
		reply.resolve("committed");
		const operation = await work;
		assertEquals(decisions.every((ids) => ids.length === 0), true);
		session.finish(operation);
		stop();
		await session.close();
	});
}

for (const front of ["command", "action"] as const) {
	Deno.test(`${front} captures its selected authority before its first asynchronous read`, async () => {
		let current = snapshot();
		current.intent.directories.push({
			id: "dir",
			access: "old",
			nick: "ada",
			nickAllocation: "exact",
			home: true,
			standing: null,
		});
		let prepared = 0;
		const session = viewer({
			snapshot: () => Promise.resolve(current),
			prepareCommand: () => {
				prepared++;
				throw new Error("must not prepare");
			},
		});
		await session.refresh();
		const result = Promise.allSettled([
			front === "command"
				? session.command("setDirectoryStanding", ["dir", "away"])
				: session.actions.run("setDirectoryStanding", ["dir", "away"]),
		]);
		current = structuredClone(current);
		current.revision = "2";
		current.intent.directories[0].access = "replacement";
		const [outcome] = await result;
		assertEquals(outcome.status, "rejected");
		if (outcome.status === "rejected") {
			assert(
				outcome.reason.message.includes("selection changed"),
				"refuse the retired authority before preparation",
			);
		}
		assertEquals(prepared, 0);
		assertEquals(session.pending, []);
		await session.close();
	});
}

for (const keep of [false, true]) {
	for (const change of ["room startup", "retention choice", "erasure"] as const) {
		Deno.test(`history ${keep}: admission fences ${change} at the retention owner`, async () => {
			let current = snapshot();
			current.intent.keepHistory = !keep;
			current.intent.conversations.push({
				kind: "room",
				id: "room",
				directory: "directory",
				source: "source",
				access: "access",
				name: "room",
				control: null,
				reconnect: "requested",
				standing: null,
				draft: "",
			});
			let prepared = 0;
			const session = viewer({
				snapshot: () => Promise.resolve(current),
				prepareCommand: (id: string, revision: string, name: string, args: string[]) => {
					prepared++;
					return Promise.resolve({
						originalIntent: () => [id, Number(revision), name, args],
						submit: () => Promise.resolve("committed"),
						status: () => Promise.resolve("committed"),
						free() {},
					});
				},
			});
			try {
				await session.refresh();
				const work = Promise.allSettled([session.command("chooseHistoryRetention", [String(keep)])]);
				current = structuredClone(current);
				current.revision = "2";
				if (change === "room startup") current.intent.conversations[0].inbox = "callback";
				else if (change === "retention choice") current.intent.keepHistory = keep;
				else current.intent.historyErasure = "original-erasure";
				const [outcome] = await work;
				assertEquals(outcome.status, change === "room startup" ? "fulfilled" : "rejected");
				assertEquals(prepared, change === "room startup" ? 1 : 0);
				if (outcome.status === "fulfilled") session.finish(outcome.value);
				if (outcome.status === "rejected") {
					assert(
						outcome.reason.message.includes("selection changed"),
						"the changed retention owner refuses admission",
					);
				}
			} finally {
				await session.close();
			}
		});
	}
}

for (const level of ["global", "directory", "room"] as const) {
	Deno.test(`effective standing projects and conflicts at its ${level} owner`, async () => {
		const current = snapshot();
		current.intent.directories.push({
			id: "directory",
			source: "source",
			access: "access",
			standing: level === "directory" ? "here" : null,
			nick: "reader",
			nickAllocation: "exact",
			home: true,
		});
		current.intent.conversations.push({
			kind: "room",
			id: "room",
			directory: "directory",
			source: "room-source",
			access: "room-access",
			name: "room",
			control: null,
			reconnect: "requested",
			standing: level === "room" ? "here" : null,
			draft: "",
		});
		const session = viewer({ snapshot: () => Promise.resolve(current) });
		await session.refresh();
		const name = level === "global"
			? "setStanding"
			: level === "directory"
			? "setDirectoryStanding"
			: "setRoomStanding";
		const target = level === "global" ? null : level;
		session.effects.reserve("effective", "setEffectiveStanding", ["room", "away"]);
		assertEquals(session.effects.standing(name, target, "here"), "away");
		let refusal = "";
		try {
			session.effects.reserve("other", name, target == null ? ["here"] : [target, "here"]);
		} catch (error) {
			refusal = String(error);
		}
		assert(refusal.includes("still pending"), "the effective scope blocks its owning setting");
		await session.close();
	});
}
