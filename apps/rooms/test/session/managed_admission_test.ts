// One viewer prepares commands in order. Other viewers retain revision fences.
import { assert, assertEquals } from "../assert.ts";
import { ResultAcquisitionError } from "../../web/ui/session/managed/operation.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { initializeApplication } from "../support/application.ts";
import { SubmissionRefused } from "../../web/ui/session/managed/acquisition.ts";
import { refusalText } from "../../lib/text/failure.ts";
import { retryCountdown } from "../../lib/text/admission.ts";
import { ROOMS_FAILURES } from "../../lib/failure_data.ts";

await initializeApplication();

Deno.test("terminal observation wakes admission and releases its completed wrapper without resubmission", async () => {
	let status = "pending";
	let submissions = 0;
	const waiting = deferred<void>();
	const failure = "No relay answered a register request";
	const received = deferred<string>();
	let freed = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: (id: string, revision: string, name: string, args: string[]) =>
			Promise.resolve({
				originalIntent: () => [id, Number(revision), name, args],
				submit: () => {
					submissions++;
					return Promise.resolve({ status: "pending" });
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

// The session refuses an over-budget introduction before any receipt exists.
// That refusal admits nothing, so it is the person's to read and press again,
// never a held operation asking them to decide.
Deno.test("a rate-limited admission keeps nothing, asks no decision, and a later press succeeds", async () => {
	const reason = "glowcap error -12: rate-limited: retry-after-ms=275; scope=introduction; owner=session";
	let submissions = 0;
	let freed = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () =>
			Promise.resolve({
				submit: () =>
					Promise.resolve(
						++submissions === 1
							? {
								status: "refused",
								reason,
								failure: {
									status: -12,
									reason,
									code: "rate-limited",
									detail: "retry-after-ms=275; scope=introduction; owner=session",
									retryAfterMs: 275,
									scope: "introduction",
									owner: "session",
								},
							}
							: { status: "committed" },
					),
				status: () => Promise.resolve("committed"),
				free: () => freed++,
			}),
	});
	const decisions: string[][] = [];
	const stop = session.subscribe(() => decisions.push([...session.recoverable]));
	const press = () => {
		const operation = crypto.randomUUID();
		return session.execute(
			operation,
			() => session.command("startDirect", ["directory", "peer", "registration", "opening"], operation),
			(command) => Promise.resolve(session.finish(command)),
		);
	};
	const [refused] = await Promise.allSettled([press()]);
	assert(refused.status === "rejected" && refused.reason instanceof SubmissionRefused, String(refused));
	const limited = ROOMS_FAILURES["rate-limited"];
	assertEquals(
		refusalText(refused.reason),
		`${limited.summary} ${retryCountdown(1)} (rate-limited: Starting conversations in this session.)`,
	);
	assertEquals(session.pending, []);
	assertEquals(session.recoverable, []);
	assertEquals(freed, 1, "the refused request is freed");
	await press();
	assertEquals(submissions, 2);
	assertEquals(session.pending, []);
	assert(decisions.every((ids) => ids.length === 0), "a refusal asked for a decision");
	stop();
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
					return { status: "committed" };
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
				submit: () => Promise.resolve({ status: "pending" }),
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
				submit: () => Promise.resolve({ status: "pending" }),
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
					return Promise.resolve({ status: "unknown" });
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
				submit: () => Promise.resolve({ status: "unknown" }),
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
				submit: () => Promise.resolve({ status: "unsent" }),
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
				submit: () => Promise.resolve({ status: "committed" }),
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
						if (++submissions > 1) return Promise.resolve({ status: "committed" });
						if (change === "uncertain") return Promise.reject(new Error("acknowledgment lost"));
						current = structuredClone(current);
						current.revision = "2";
						const direct = current.intent.conversations[1];
						if (direct.kind !== "direct") throw new Error("expected direct selection");
						if (change === "callback") direct.inbox = "installed-callback";
						else direct[change] = "replacement";
						return Promise.resolve({ status: "conflict" });
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
				submit: () => Promise.resolve({ status }),
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
				return Promise.resolve({ status: "pending" });
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
					return { status: "pending" };
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
		const reply = deferred<{ status: string }>();
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
		reply.resolve({ status: "committed" });
		const operation = await work;
		assertEquals(decisions.every((ids) => ids.length === 0), true);
		session.finish(operation);
		stop();
		await session.close();
	});
}

Deno.test("an unsent receipt keeps retry advice even when its result alone cannot prove absence", async () => {
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () =>
			Promise.resolve({
				submit: () => Promise.resolve({ status: "unsent" }),
				status: () => Promise.resolve("unsent"),
				result: () =>
					Promise.resolve({
						observationFailure: "message rate",
						knownAbsent: false,
						failure: {
							status: -12,
							reason: "message rate",
							code: "rate-limited",
							detail: "limited",
							retryAfterMs: 6000,
							scope: "message",
							owner: "session",
						},
					}),
				free() {},
			}),
	});
	try {
		const [result] = await Promise.allSettled([session.command("operations", [], "rate")]);
		assert(result.status === "rejected", "the request must refuse");
		assert(
			refusalText(result.reason).includes(retryCountdown(6)),
			"settlement must preserve the exact receipt's retry advice",
		);
	} finally {
		await session.close();
	}
});
