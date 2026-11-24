// Recovery controls name retained tasks that have stopped, never live work.
import { refusalCode } from "../support/browser_failure.ts";
import { assert, assertEquals } from "../assert.ts";
import { settle } from "../support/wait.ts";
import { connectionLost } from "../../lib/text/failure.ts";
import { closed, linkedWorkspace, oneLink } from "../support/managed_link.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import type { RoomsManagedCommand, RoomsManagedRecoveredEffect } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ObservationView } from "../../web/ui/session/managed/model.ts";
import { restoreEffects, resumeEffect } from "../../web/ui/session/managed/recovery.ts";
import {
	readResult,
	ResultAcquisitionError,
	ResultExpired,
	TerminalObservationError,
} from "../../web/ui/session/managed/operation.ts";
import { fakeHandle } from "../support/managed_link.ts";

Deno.test("paused unknown execution resumes before reading its unavailable result", async () => {
	let reads = 0;
	let retired = false;
	const request = fakeHandle<RoomsManagedRecoveredEffect>({
		status: () => Promise.resolve("unknown"),
		resume: () => Promise.resolve("pending"),
		result: () => {
			reads++;
			return Promise.reject(new Error("The original operation is unknown. Its receipt remains held."));
		},
	});
	assertEquals(await resumeEffect(request, () => retired = true), "pending");
	assertEquals([reads, retired], [0, false]);
});

Deno.test("refused resume retires only a terminal original observation", async () => {
	for (const terminal of [false, true]) {
		let retired = false;
		const refusal = new Error("the original executor is unavailable");
		const request = fakeHandle<RoomsManagedRecoveredEffect>({
			status: () => Promise.resolve("unknown"),
			resume: () => Promise.reject(refusal),
			result: () =>
				terminal
					? Promise.resolve({ observationFailure: "the connection ended" })
					: Promise.reject(new Error("the result read was refused")),
		});
		const error = await resumeEffect(request, () => retired = true).then(() => undefined, (error) => error);
		assertEquals(retired, terminal);
		assertEquals(terminal ? error instanceof TerminalObservationError : error === refusal, true);
	}
});

Deno.test("startup releases terminal diagnostics and retains interrupted or refused reads", async () => {
	const parked = deferred<ObservationView>();
	const view: ObservationView = {
		cursor: new Uint8Array(56),
		source: { status: "active", effective: { permissions: ["resolvePending"] } },
		changed: false,
		resync: false,
	};
	const freed: string[] = [];
	const failures: unknown[] = [];
	const session = viewer({
		prepareObservation: () =>
			Promise.resolve({
				submit: () =>
					Promise.resolve({
						poll: () => Promise.resolve(view),
						receive: () => parked.promise,
						cancel: () => {
							parked.resolve(view);
							return Promise.resolve();
						},
						free() {},
					}),
				free() {},
			}),
		effects: () =>
			Promise.resolve(
				["terminal", "interrupted", "refused"].map((operation) => ({ operation, status: "unknown" })),
			),
		recoverEffect: (id: string) =>
			Promise.resolve({
				result: () =>
					id === "terminal" ? Promise.resolve({ observationFailure: "relay refused" }) : Promise.reject(
						new Error(id === "interrupted" ? "observation remains held" : "source was paused"),
					),
				free: () => freed.push(id),
			}),
	}, (_source, error) => failures.push(error));
	await session.start();
	assertEquals(session.pending, ["interrupted", "refused"]);
	assertEquals(freed.filter((id) => id === "terminal"), ["terminal"]);
	assertEquals(failures.length, 3);
	await session.close();
});

Deno.test("startup skips a listed receipt whose release already happened", async () => {
	const failures: unknown[] = [];
	const asked: string[] = [];
	const { workspace } = linkedWorkspace("released", [], {
		effects: () =>
			Promise.resolve([{ operation: "released", status: "committed", resumable: false, released: false }]),
		// The session answers Void to the receipt's intent, which the binding
		// reads as no receipt to recover.
		recoverEffect: (id: string) => {
			asked.push(id);
			return Promise.resolve(undefined);
		},
	});
	const session = viewer(workspace, (_source, error) => failures.push(error));
	await session.start();
	assertEquals([asked, session.pending, failures], [["released"], [], []]);
	await session.close();
});

for (const expiredDuringResult of [false, true]) {
	Deno.test(`startup tolerates a terminal receipt leaving the replay window, duringResult=${expiredDuringResult}`, async () => {
		const parked = deferred<ObservationView>();
		const view: ObservationView = {
			cursor: new Uint8Array(56),
			source: { status: "active", effective: { permissions: ["resolvePending"] } },
			changed: false,
			resync: false,
		};
		let recovered = 0;
		let freed = 0;
		const failures: unknown[] = [];
		const session = viewer({
			prepareObservation: () =>
				Promise.resolve({
					submit: () =>
						Promise.resolve({
							poll: () => Promise.resolve(view),
							receive: () => parked.promise,
							cancel: () => {
								parked.resolve(view);
								return Promise.resolve();
							},
							free() {},
						}),
					free() {},
				}),
			effects: () => Promise.resolve([{ operation: "completed", status: "committed" }]),
			recoverEffect: () =>
				Promise.resolve(
					++recovered === 1 && expiredDuringResult
						? {
							result: () => Promise.reject(new Error("receipt retired by another viewer")),
							free: () => freed++,
						}
						: undefined,
				),
		}, (_source, error) => failures.push(error));
		await session.start();
		assertEquals(session.pending, []);
		assertEquals(session.recoverable, []);
		assertEquals(freed, expiredDuringResult ? 1 : 0);
		assertEquals(failures, []);
		await session.close();
	});
}

Deno.test("command admission hides live work and exposes its exact uncertain receipt", async () => {
	const submitted = deferred<{ status: string }>();
	const ready = deferred<void>();
	let status = "pending";
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		recoverEffect: () =>
			Promise.resolve({
				status: () => Promise.resolve("pending"),
				resume: () => ready.promise.then(() => "committed"),
				free() {},
			}),
	});
	const request = fakeHandle<RoomsManagedCommand>({
		submit: () => submitted.promise,
		status: () => Promise.resolve(status),
		free() {},
	});
	const admissions: string[][] = [];
	session.subscribe(() => admissions.push([...session.recoverable]));
	const operation = session.perform("original", () => Promise.resolve(request));
	const uncertain = Promise.allSettled([operation]);
	await settle();
	assertEquals(session.pending, ["original"]);
	assertEquals(session.recoverable, []);
	assertEquals(admissions.every((ids) => ids.length === 0), true);
	submitted.resolve({ status: "unknown" });
	// The original request cannot prove a committed receipt.
	status = "failed";
	await uncertain;
	assertEquals(session.recoverable, ["original"]);
	const recovery = session.resume("original");
	assertEquals(session.recoverable, []);
	status = "committed";
	ready.resolve();
	session.finish(await recovery);
	assertEquals(session.recoverable, []);
	await session.close();
});

Deno.test("a running gesture hides its retained command through result acquisition", async () => {
	const completion = deferred<void>();
	const session = viewer({ snapshot: () => Promise.resolve(snapshot()) });
	let command: Awaited<ReturnType<typeof session.perform>> | null = null;
	const gesture = session.execute("original", async () => {
		command = await session.perform("original", () =>
			Promise.resolve(fakeHandle<RoomsManagedCommand>({
				submit: () => Promise.resolve({ status: "committed" }),
				status: () => Promise.resolve("committed"),
				free() {},
			})));
		return command;
	}, async () => {
		await completion.promise;
		assert(command != null, "the gesture's command was admitted");
		session.finish(command);
	});
	for (let turn = 0; turn < 8; turn++) await Promise.resolve();
	assertEquals(session.pending, ["original"]);
	assertEquals(session.recoverable, []);
	completion.resolve();
	await gesture;
	assertEquals(session.recoverable, []);
	await session.close();
});

Deno.test("an acquisition decision appears after uncertainty and disappears during exact retry", async () => {
	const submitted = deferred<{ status: "uncertain" }>();
	const retry = deferred<{ status: "committed" }>();
	let attempts = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareAcquisition: () =>
			Promise.resolve({
				submit: () => (++attempts === 1 ? submitted : retry).promise,
				free() {},
			}),
	});
	const acquisition = session.actions.replace(snapshot());
	const uncertain = Promise.allSettled([acquisition]);
	for (let turn = 0; turn < 4; turn++) await Promise.resolve();
	assertEquals(session.actions.pending.length, 1);
	assertEquals(session.actions.recoverable, []);
	submitted.resolve({ status: "uncertain" });
	await uncertain;
	assertEquals(session.actions.recoverable, session.actions.pending);
	const recovering = session.actions.recoverAcquisition(session.actions.pending[0]);
	assertEquals(session.actions.recoverable, []);
	retry.resolve({ status: "committed" });
	await recovering;
	assertEquals(session.actions.recoverable, []);
	assertEquals(attempts, 2);
	await session.close();
});

Deno.test("an import still held after an uncertain reply keeps its state, so only the same import retries", async () => {
	let prepared = 0, attempts = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareConfigurationImport: () => {
			prepared++;
			return Promise.resolve({
				submit: () => Promise.resolve({ status: ++attempts === 1 ? "uncertain" : "committed" }),
				free() {},
			});
		},
	});
	await Promise.allSettled([session.actions.importState("{}")]);
	assertEquals(session.actions.recoverable.length, 1, "the uncertain import is held");
	const other = await session.actions.importState('{"other":true}').then(() => null, (error: unknown) => error);
	assertEquals(refusalCode(other), "local-import-in-progress");
	await session.actions.importState("{}");
	assertEquals([prepared, attempts, session.actions.pending.length], [1, 2, 0], "the same request retried once");
	await session.actions.importState('{"other":true}');
	assertEquals(prepared, 2, "a settled import frees the next one");
	await session.close();
});
Deno.test("a retained receipt another viewer retired is released when recovery finds it absent", async () => {
	const submitted = deferred<{ status: string }>();
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		recoverEffect: () => Promise.resolve(undefined),
	});
	const request = fakeHandle<RoomsManagedCommand>({
		submit: () => submitted.promise,
		status: () => Promise.resolve("failed"),
		free() {},
	});
	const uncertain = Promise.allSettled([session.perform("retired", () => Promise.resolve(request))]);
	submitted.resolve({ status: "unknown" });
	await uncertain;
	assertEquals(session.recoverable, ["retired"]);
	assertEquals(await session.completeOperation("retired"), true);
	assertEquals([session.pending, session.recoverable], [[], []]);
	await session.close();
});

Deno.test("a committed receipt whose result expired with its session settles instead of failing forever", async () => {
	const submitted = deferred<{ status: string }>();
	let status = "failed";
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		recoverEffect: () =>
			Promise.resolve({
				status: () => Promise.resolve("committed"),
				resume: () => Promise.resolve("committed"),
				free() {},
			}),
	});
	const request = fakeHandle<RoomsManagedCommand>({
		submit: () => submitted.promise,
		status: () => Promise.resolve(status),
		result: () =>
			Promise.reject(Object.assign(new Error("expired result"), { status: -12, reason: "LiveReferenceExpired" })),
		adopted: () => Promise.resolve(false),
		free() {},
	});
	const uncertain = Promise.allSettled([session.perform("expired", () => Promise.resolve(request))]);
	submitted.resolve({ status: "unknown" });
	await uncertain;
	assertEquals(session.recoverable, ["expired"]);
	status = "committed";
	assertEquals(await session.completeOperation("expired"), true);
	assertEquals([session.pending, session.recoverable], [[], []]);
	await session.close();
});

Deno.test("only the projected expiry fields identify an expired result", async () => {
	const reading = (error: Error) => readResult({ result: () => Promise.reject(error) });
	const projected = (status: number, reason: string) => Object.assign(new Error("diagnostic"), { status, reason });
	const [expired] = await Promise.allSettled([reading(projected(-12, "LiveReferenceExpired"))]);
	assert(expired.status === "rejected" && expired.reason instanceof ResultExpired, "the projected reason expires");
	for (
		const error of [
			new Error("glowcap error -12: LiveReferenceExpired"),
			new Error("glowcap error -12: the peer said LiveReferenceExpired"),
			new Error("glowcap error -8: LiveReferenceExpired"),
			new Error("LiveReferenceExpired"),
			projected(-8, "LiveReferenceExpired"),
			projected(-12, "the peer said LiveReferenceExpired"),
		]
	) {
		const [outcome] = await Promise.allSettled([reading(error)]);
		assert(outcome.status === "rejected" && outcome.reason === error, error.message);
	}
});

Deno.test("letting a receipt go releases it upstream and forgets the held operation", async () => {
	const submitted = deferred<{ status: string }>();
	const released: string[] = [];
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		recoverEffect: (id: string) =>
			Promise.resolve({
				release: () => {
					released.push(id);
					return Promise.resolve("released");
				},
				free() {},
			}),
	});
	const request = fakeHandle<RoomsManagedCommand>({
		submit: () => submitted.promise,
		status: () => Promise.resolve("failed"),
		free() {},
	});
	const uncertain = Promise.allSettled([session.perform("abandoned", () => Promise.resolve(request))]);
	submitted.resolve({ status: "unknown" });
	await uncertain;
	assertEquals(session.recoverable, ["abandoned"]);
	await session.releaseOperation("abandoned");
	assertEquals(released, ["abandoned"]);
	assertEquals([session.pending, session.recoverable], [[], []]);
	await session.close();
});

Deno.test("an operation still running here cannot be let go", async () => {
	const submitted = deferred<{ status: string }>();
	let released = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		recoverEffect: () => {
			released++;
			return Promise.resolve(undefined);
		},
	});
	const request = fakeHandle<RoomsManagedCommand>({
		submit: () => submitted.promise,
		status: () => Promise.resolve("pending"),
		free() {},
	});
	const running = Promise.allSettled([session.perform("live", () => Promise.resolve(request))]);
	await settle();
	assertEquals(session.pending, ["live"]);
	const refused = await session.releaseOperation("live").then(() => null, refusalCode);
	assertEquals(refused, "local-change-busy");
	assertEquals(released, 0, "the session was never asked to release a change still in flight");
	assertEquals(session.pending, ["live"]);
	submitted.resolve({ status: "committed" });
	await running;
	await session.close();
});

Deno.test("an uncertain result acquisition keeps its receipt until the original commit resolves", async () => {
	let inspected = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		recoverEffect: () => {
			inspected++;
			return Promise.resolve(undefined);
		},
	});
	const request = fakeHandle<RoomsManagedCommand>({
		submit: () => Promise.resolve({ status: "committed" }),
		status: () => Promise.resolve("committed"),
		prepareResultAcquisition: () =>
			Promise.resolve({ submit: () => Promise.resolve({ status: "uncertain" }), free() {} }),
		free() {},
	});
	const operation = await session.perform("acquiring", () => Promise.resolve(request));
	await operation.acquire(snapshot(), []).catch(() => {});
	assertEquals(operation.acquiring, true);
	assertEquals(await session.releaseOperation(operation.id).then(() => false, () => true), true);
	assertEquals([inspected, session.pending], [0, ["acquiring"]]);
	await session.close();
});

Deno.test("failed resume preserves its earlier committed status for the operation owner", async () => {
	const cause = new Error("resume unavailable");
	const observed: string[] = [];
	const request = fakeHandle<RoomsManagedRecoveredEffect>({
		status: () => Promise.resolve("committed"),
		resume: () => Promise.reject(cause),
	});
	const outcome = (await Promise.allSettled([resumeEffect(request, () => {}, (status) => observed.push(status))]))[0];
	assertEquals(observed, ["committed"]);
	assertEquals(outcome.status, "rejected");
	if (outcome.status === "rejected") {
		assertEquals(outcome.reason instanceof ResultAcquisitionError, true);
		assertEquals(outcome.reason.cause, cause);
	}
});

Deno.test("startup retains committed inventory evidence before reading a recovered result", async () => {
	const request = fakeHandle<RoomsManagedRecoveredEffect>({ free() {} });
	const workspace = {
		effects: () => Promise.resolve([{ operation: "known", status: "committed" }]),
		recoverEffect: () => Promise.resolve(request),
	};
	const session = viewer(workspace);
	let committed = false;
	try {
		await restoreEffects({
			port: oneLink(workspace),
			known: () => false,
			retain: (operation) => {
				committed = operation.committed;
			},
			finish: () => {},
			complete: (operation) => {
				operation.finish();
				return Promise.resolve();
			},
			report: () => {},
		});
		assertEquals(committed, true);
	} finally {
		await session.close();
	}
});

Deno.test("a lost connection while a committed change resumes stays a lost connection", async () => {
	const error = await resumeEffect(
		fakeHandle<RoomsManagedRecoveredEffect>({
			status: () => Promise.resolve("committed"),
			resume: () => Promise.reject(closed()),
		}),
		() => {},
	).then(() => null, (failure: unknown) => failure);
	assert(connectionLost(error), "the break is the link's to heal, not a result that needs recovery");
});
