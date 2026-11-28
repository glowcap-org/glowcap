// Reconnection changes live custody, preserving data only for the same peer.
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import {
	actionSession,
	backedOff,
	closed,
	FakeClock,
	fakeHandle,
	linkedWorkspace,
	oneLink,
	operationOf,
	relinking,
	request,
} from "../support/managed_link.ts";
import { settle, until } from "../support/wait.ts";
import { browserFailure } from "../support/browser_failure.ts";
import { ManagedOperation, ResultAcquisitionError } from "../../web/ui/session/managed/operation.ts";
import { RELEASE_ASK_MS } from "../../web/ui/session/managed/release.ts";
import type { ManagedNavigation } from "../../web/ui/session/managed/navigation.ts";
import { completeResult } from "../../web/ui/session/managed/completion.ts";
import { ManagedActions } from "../../web/ui/session/managed/actions.ts";
import { cannotSendRegistrationEnded } from "../../lib/text/conversation.ts";
import { failureView, LocalRefusal } from "../../lib/text/failure.ts";
import { LOCAL_REFUSALS } from "../../lib/text/local_refusals.ts";
import { RUNNING_BOUND_MS } from "../../lib/limits.ts";
import type { DirectIntent, WorkspaceSnapshot } from "../../web/ui/session/managed/model.ts";
import type { ConversationOpening } from "../../web/ui/session/managed/openings.ts";
import { acquireDirect } from "../../web/ui/session/managed/direct.ts";

function saved() {
	const current = snapshot();
	current.intent.directories.push({
		id: "directory",
		access: "directory-access",
		source: "directory-source",
		name: "local-name",
		inbox: "local-callback",
		home: true,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	const row: DirectIntent = {
		kind: "direct",
		id: "saved",
		directory: "directory",
		peer: "bob",
		source: "old-source",
		access: null,
		closed: true,
		draft: "saved draft",
		introduction: {
			access: "directory-access",
			name: "old-name",
			callback: "old-callback",
			registration: "peer-registration",
			opening: "old-opening",
		},
	};
	current.intent.conversations.push(row);
	current.intent.active = row.id;
	return current;
}
/** The direct row at `at` in `current`. */
function direct(current: WorkspaceSnapshot, at = 0): DirectIntent {
	const row = current.intent.conversations.at(at);
	assert(row?.kind === "direct", "the row is a direct conversation");
	return row;
}
/** The introduction `row` was opened under, which every saved row holds. */
function introduction(row: DirectIntent): NonNullable<DirectIntent["introduction"]> {
	assert(row.introduction != null, "the row holds its introduction");
	return row.introduction;
}

for (const change of ["none", "draft", "source", "removed", "peer"] as const) {
	Deno.test(`direct reconnect adoption preserves data and fences ${change} during conflict`, async () => {
		const current = saved();
		if (change === "peer") {
			introduction(direct(current)).registration = "different-peer";
		}
		let preparations = 0;
		const operation = operationOf("reconnect", {
			result: () => Promise.resolve({ inbox: "new-route" }),
			adopted: () => Promise.resolve(false),
			originalIntent:
				() => ["reconnect", 1, "startDirect", ["directory", "bob", "peer-registration", "new-opening"]],
			prepareResultAcquisition: (_revision: string, _imports: string, _releases: string, intent: string) => {
				preparations++;
				return Promise.resolve({
					submit: () => {
						if (preparations === 1 && change !== "none" && change !== "peer") {
							current.revision = "2";
							if (change === "draft") current.intent.conversations[0].draft = "latest draft";
							if (change === "source") current.intent.conversations[0].source = "replacement-source";
							if (change === "removed") current.intent.conversations = [];
							return Promise.resolve({ status: "conflict" });
						}
						current.intent = JSON.parse(intent);
						return Promise.resolve({ status: "committed" });
					},
					free() {},
				});
			},
			free() {},
		});
		const session = viewer({ snapshot: () => Promise.resolve(current) });
		try {
			const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
			if (change === "source" || change === "removed") {
				assertEquals(outcome.status, "rejected");
				assertEquals(preparations, 1, "changed targets cannot acquire the old result");
				assertEquals(operation.acquired, false);
			} else {
				assertEquals(outcome.status, "fulfilled");
				assertEquals(current.intent.conversations.length, change === "peer" ? 2 : 1);
				const row = direct(current, -1);
				assertEquals(
					[row.id, row.draft],
					change === "peer"
						? ["reconnect", ""]
						: ["saved", change === "draft" ? "latest draft" : "saved draft"],
				);
				assert(!row.closed && row.access != null, "only committed route custody reopens the conversation");
				assertEquals(row.introduction?.registration, "peer-registration");
				assertEquals(row.introduction?.opening, "new-opening");
				assertEquals(current.intent.active, "saved", "adoption is independent of navigation");
			}
		} finally {
			await operation.close();
			await session.close();
		}
	});
}

Deno.test("direct reconnect refuses a reused name before introduction", async () => {
	const current = saved();
	let freed = 0;
	let introduced = 0;
	const workspace = {
		directoryReader: () =>
			Promise.resolve({ memberRegistration: () => Promise.resolve("different-peer"), free: () => freed++ }),
	};
	const session = actionSession(workspace, {
		readBeforeSending: () => Promise.resolve(current),
		readNow: () => Promise.resolve(current),
		command: () => {
			introduced++;
			throw new Error("unexpected introduction");
		},
	});
	const [outcome] = await Promise.allSettled([
		new ManagedActions(session, oneLink(workspace)).direct("directory", "bob", false, "peer-registration"),
	]);
	assertEquals(outcome.status, "rejected");
	if (outcome.status === "rejected") {
		assert(outcome.reason instanceof LocalRefusal, "a reused name is a refusal the page words");
		assertEquals(outcome.reason.message, cannotSendRegistrationEnded);
	}
	assertEquals([freed, introduced], [1, 0]);
});

Deno.test("direct action returns the adopted conversation identity after reconnect", async () => {
	const current = saved();
	let opening = "";
	const selected: string[] = [];
	const workspace = {
		directoryReader: () =>
			Promise.resolve({ memberRegistration: () => Promise.resolve("peer-registration"), free() {} }),
	};
	const session = actionSession(workspace, {
		readBeforeSending: () => Promise.resolve(current),
		readNow: () => Promise.resolve(current),
		command: (_name: string, args: string[]) => {
			opening = args[3];
			return Promise.resolve(fakeHandle<ManagedOperation>({
				id: "receipt",
				result: () => Promise.resolve({ inbox: "route" }),
			}));
		},
		completeResult: () => {
			const row = direct(current);
			row.closed = false;
			row.access = "route";
			introduction(row).opening = opening;
			return Promise.resolve();
		},
		navigation: fakeHandle<ManagedNavigation>({
			selectAfterCommit: (id: string) => {
				selected.push(id);
				return Promise.resolve();
			},
		}),
	});
	assertEquals(
		await new ManagedActions(session, oneLink(workspace)).direct("directory", "bob", true, "peer-registration"),
		"saved",
	);
	assertEquals(selected, ["saved"]);
});

/** The saved row open, introduced under the directory's earlier contact. The
 * member opened it when the session accepted their introduction and holds no
 * route yet. This session opened it when it holds the member's route. */
function open(opener: "member" | "session") {
	const current = saved();
	const row = direct(current);
	row.closed = false;
	row.peer = "Bob";
	if (opener === "session") row.access = "old-route";
	else introduction(row).opening = "their-opening";
	return current;
}

for (
	const change of [
		"ready",
		"other room",
		"other opening",
		"other inbox",
		"closed",
		"expired",
		"rotated after sending",
	] as const
) {
	Deno.test(`one invitation on an incoming direct line: ${change}`, async () => {
		let current = open("member");
		const room = {
			kind: "room" as const,
			id: "work",
			directory: "directory",
			name: "work",
			source: "source",
			access: "entrance",
			control: null,
			reconnect: "requested" as const,
			standing: null,
			draft: "",
		};
		direct(current).inbox = "inbox";
		current.intent.conversations.push(room);
		const clock = new FakeClock();
		const sent: string[][] = [];
		const receipt = Promise.withResolvers<void>();
		const session = viewer(
			{
				snapshot: () => Promise.resolve(current),
				directoryReader: () =>
					Promise.resolve({
						memberRegistration: () => Promise.resolve("peer-registration"),
						free() {},
					}),
				prepareCommand: (id: string, revision: string, name: string, args: string[]) =>
					Promise.resolve({
						originalIntent: () => [id, Number(revision), name, args],
						submit: () => {
							sent.push([name, ...args]);
							return Promise.resolve({ status: "committed" });
						},
						status: () => Promise.resolve("committed"),
						result: async () => {
							if (change === "rotated after sending") await receipt.promise;
							return null;
						},
						adopted: () => Promise.resolve(true),
						release: () => Promise.resolve("released"),
						free() {},
					}),
			},
			undefined,
			undefined,
			true,
			clock,
		);
		try {
			const invites = Promise.allSettled([
				session.actions.invite(room, "Bob"),
				session.actions.invite(room, "Bob"),
			]);
			await until(() => clock.waiting > 0, "the missing direct return route");
			assertEquals(sent, []);
			current = structuredClone(current);
			current.revision = "2";
			const line = direct(current);
			line.access = "return-route";
			const carried = current.intent.conversations[1];
			assert(carried.kind === "room", "the invitation started from a room");
			carried.seat = "refreshed-seat";
			if (change === "other room") current.intent.conversations[1].access = "another-entrance";
			if (change === "other opening") introduction(line).opening = "replacement";
			if (change === "other inbox") line.inbox = "replacement-inbox";
			if (change === "closed") line.closed = true;
			if (change === "expired") clock.advance(30_000);
			else await session.readNow();
			if (change === "rotated after sending") {
				await until(() => sent.length === 1, "the invitation on the original route");
				current = structuredClone(current);
				current.revision = "3";
				direct(current).access = "replacement-route";
				await session.readNow();
				const later = Promise.allSettled([session.actions.invite(room, "Bob")]);
				await settle();
				receipt.resolve();
				const [result] = await later;
				assert(
					result.status === "rejected" && LocalRefusal.is(result.reason, "invite-selection-changed"),
					"the replacement cannot claim the original invitation",
				);
			}
			const outcomes = await invites;
			const offered = change === "ready" || change === "rotated after sending";
			assertEquals(sent, offered ? [["offerRoom", room.id, line.id]] : []);
			for (const result of outcomes) {
				if (offered) {
					if (result.status === "rejected") throw result.reason;
				} else {
					assert(result.status === "rejected", "the invitation ended without sending");
					assert(
						LocalRefusal.is(
							result.reason,
							change === "expired" ? "invite-route-pending" : "invite-selection-changed",
						),
						"the invitation explains why it ended",
					);
				}
			}
		} finally {
			receipt.resolve();
			await session.close();
		}
	});
}

for (const opener of ["member", "session"] as const) {
	Deno.test(`a direct route given back to the row the ${opener} opened releases its receipt`, async () => {
		const current = open(opener);
		const before = structuredClone(current.intent);
		let released = 0;
		const operation = operationOf("again", {
			result: () => Promise.resolve({ inbox: "surplus-route" }),
			adopted: () => Promise.resolve(false),
			originalIntent: () => ["again", 1, "startDirect", ["directory", "bob", "peer-registration", "new-opening"]],
			prepareResultAcquisition: () => {
				throw new Error("a second open row was prepared");
			},
			release: () => {
				released++;
				return Promise.resolve("released");
			},
			free() {},
		});
		const session = viewer({ snapshot: () => Promise.resolve(current) });
		try {
			await completeResult(session, operation);
			assertEquals([released, operation.acquired], [1, false]);
			assertEquals(current.intent, before);
		} finally {
			await operation.close();
			await session.close();
		}
	});

	Deno.test(`a direct action reaches the row the ${opener} opened after the directory registers again`, async () => {
		const current = open(opener);
		let introduced = 0;
		const session = actionSession({
			directoryReader: () =>
				Promise.resolve({ memberRegistration: () => Promise.resolve("peer-registration"), free() {} }),
		}, {
			readBeforeSending: () => Promise.resolve(current),
			readNow: () => Promise.resolve(current),
			command: () => {
				introduced++;
				throw new Error("unexpected introduction");
			},
		});
		assertEquals((await acquireDirect(session, "directory", "bob"))?.id, "saved");
		assertEquals(introduced, 0);
	});
}

/** A route given back to the row the member opened, whose session answers
 * each release with the next of `answers`. */
function givenBack(answers: unknown[]) {
	const current = open("member");
	const asks: unknown[] = [];
	const operation = operationOf("again", {
		result: () => Promise.resolve({ inbox: "surplus-route" }),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["again", 1, "startDirect", ["directory", "bob", "peer-registration", "new-opening"]],
		prepareResultAcquisition: () => {
			throw new Error("a second open row was prepared");
		},
		release: () => {
			asks.push(answers[asks.length]);
			return Promise.resolve(answers[asks.length - 1]);
		},
		free() {},
	});
	const clock = new FakeClock();
	const session = viewer({ snapshot: () => Promise.resolve(current) }, undefined, {}, true, clock);
	return { current, before: structuredClone(current.intent), asks, operation, session, clock };
}

Deno.test("a direct route given back while its job runs is released once the job ends", async () => {
	const { current, before, asks, operation, session, clock } = givenBack(["running", "released"]);
	try {
		let done = false;
		const completing = completeResult(session, operation).then(() => {
			done = true;
		});
		await until(() => asks.length === 1, "the first release");
		await settle();
		assertEquals(done, false);
		clock.advance(RELEASE_ASK_MS);
		await completing;
		assertEquals([asks, operation.acquired], [["running", "released"], false]);
		assertEquals(current.intent, before);
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("a direct route given back while its job runs past the bound fails as still running", async () => {
	const { asks, operation, session, clock } = givenBack(Array(RUNNING_BOUND_MS / RELEASE_ASK_MS + 1).fill("running"));
	try {
		const completing = Promise.allSettled([completeResult(session, operation)]);
		for (let waited = 0; waited < RUNNING_BOUND_MS; waited += RELEASE_ASK_MS) {
			await settle();
			clock.advance(RELEASE_ASK_MS);
		}
		const [outcome] = await completing;
		assert(outcome.status === "rejected", "a release past the bound was taken as released");
		assert(outcome.reason instanceof ResultAcquisitionError, String(outcome.reason));
		assertEquals(outcome.reason.stage, "release-effect");
		assert(LocalRefusal.is(outcome.reason, "result-still-running"), outcome.reason.code);
		assert(LocalRefusal.is(outcome.reason.cause, "result-still-running"), String(outcome.reason.cause));
		assertEquals(failureView(outcome.reason).summary, LOCAL_REFUSALS["result-still-running"].summary);
		assertEquals(
			outcome.reason.message,
			LOCAL_REFUSALS["result-still-running"].summary,
		);
		assertEquals(asks.length, RUNNING_BOUND_MS / RELEASE_ASK_MS + 1);
		assert(operation.acquired === false, "the held record was consumed");
	} finally {
		await operation.close();
		await session.close();
	}
});

/** A direct route given back while its job runs: each link's workspace holds
 * its receipt, committed, and answers each ask of its release with `answer`,
 * which `asks` records by the link's name. A link in `cut` lost its
 * connection, so an ask over it fails and is not recorded. */
function runningRoute() {
	const current = open("member");
	const asks: string[] = [];
	const route = { asks, answer: "running", cut: new Set<string>() };
	const intent = ["again", 1, "startDirect", ["directory", "bob", "peer-registration", "new-opening"]];
	const receipt = (name: string) => ({
		status: () => Promise.resolve("committed"),
		resume: () => Promise.resolve("committed"),
		result: () => Promise.resolve({ inbox: "surplus-route" }),
		adopted: () => Promise.resolve(false),
		originalIntent: () => intent,
		prepareResultAcquisition: () => {
			throw new Error("a second open row was prepared");
		},
		release: () => {
			if (route.cut.has(name)) return Promise.reject(closed());
			route.asks.push(name);
			return Promise.resolve(route.answer);
		},
		free() {},
	});
	const over = (name: string) =>
		linkedWorkspace(name, [], {
			snapshot: () => Promise.resolve(current),
			recoverEffect: () => Promise.resolve(receipt(name)),
		});
	/** Send the route over the first link and complete it, as Finish does. */
	const complete = (session: ReturnType<typeof viewer>) =>
		Promise.allSettled([
			session.execute(
				"again",
				() =>
					session.perform("again", () =>
						Promise.resolve(Object.assign(
							request(
								() => Promise.resolve({ status: "committed" }),
								() => Promise.resolve("committed"),
								intent,
							),
							receipt("first"),
						))),
				(operation) => completeResult(session, operation).then(() => {}),
			),
		]);
	return { route, over, complete };
}

Deno.test("a direct route given back while its job runs keeps one bound across two relinks", async () => {
	const { route, over, complete } = runningRoute();
	const asks = route.asks;
	const [first, second, third] = [over("first"), over("second"), over("third")];
	const { session, clock, dials } = relinking(first.workspace, second.workspace, { third: third.workspace });
	await session.start();
	const completing = complete(session);
	/** Wait `asks` more asks of the running release, a pace apart. */
	const paced = async (more: number) => {
		const until = asks.length + more;
		while (asks.length < until) {
			await settle();
			clock.advance(RELEASE_ASK_MS);
		}
	};
	const relinked = async (link: { lose(error?: Error): void }, dialed: number) => {
		link.lose(closed());
		// A link lost soon after the last one waits out its back-off first.
		if (dialed > 1) await backedOff(session, clock);
		await until(() => dials() === dialed && session.link?.live === true, `link ${dialed + 1}`);
	};
	await until(() => asks.length === 1, "the first release");
	const began = clock.now();
	await paced(2);
	await relinked(first, 1);
	await paced(2);
	await relinked(second, 2);
	// Pace on until the release ends, and no further than twice its bound.
	let ended = false;
	void completing.then(() => {
		ended = true;
	});
	for (let tick = 0; tick < 2 * RUNNING_BOUND_MS / RELEASE_ASK_MS; tick++) {
		await settle();
		if (ended) break;
		clock.advance(RELEASE_ASK_MS);
	}
	const [outcome] = await completing;
	assert(outcome.status === "rejected", "a release past its bound was taken as released");
	assert(LocalRefusal.is(outcome.reason, "result-still-running"), String(outcome.reason));
	assertEquals([asks.includes("second"), asks.at(-1)], [true, "third"], "each link was asked");
	// The clock also ran through the second relink's back-off.
	const ran = clock.now() - began;
	assert(
		ran >= RUNNING_BOUND_MS && ran < RUNNING_BOUND_MS + RELEASE_ASK_MS,
		`the bound began at the first running answer, on the first link, and ended ${ran} ms later`,
	);
	// Finish asks again with a bound of its own, and the job has ended.
	route.answer = "released";
	const before = asks.length;
	await session.completeOperation("again");
	assertEquals(asks.slice(before), ["third"], "Finish asks the session again");
	await session.close();
});

Deno.test("a direct route's release bound ends with a gesture whose link was refused, so Finish later asks again", async () => {
	const { route, over, complete } = runningRoute();
	const [first, second] = [over("first"), over("second")];
	let dials = 0;
	// The first dial after the drop is refused, and only Try now dials again.
	const relink = () =>
		++dials === 1
			? Promise.reject(browserFailure(-12, "the saved access was revoked", "session-restoration-failed"))
			: Promise.resolve(second.workspace);
	const clock = new FakeClock();
	const session = viewer(first.workspace, undefined, { relink }, false, clock);
	await session.start();
	const completing = complete(session);
	await until(() => route.asks.length === 1, "the first release");
	route.cut.add("first");
	first.lose(closed());
	// The next ask goes over the lost connection.
	await until(() => session.link?.state.kind === "refused", "the refused dial");
	clock.advance(RELEASE_ASK_MS);
	const [outcome] = await completing;
	assert(outcome.status === "rejected", "the gesture ends with its link");
	assertEquals(route.asks, ["first"], "the lost connection asked nothing more");
	// Long after the first running answer, the person reaches the session again
	// and presses Finish, and the job has ended.
	clock.advance(2 * RUNNING_BOUND_MS);
	session.link?.tryNow();
	await until(() => session.link?.live === true, "the link Try now dialed");
	route.answer = "released";
	const before = route.asks.length;
	await session.completeOperation("again");
	assertEquals(route.asks.slice(before), ["second"], "Finish asks the session again");
	await session.close();
});

Deno.test("a direct route given back with an unknown release answer holds its result with that cause", async () => {
	const { asks, operation, session } = givenBack(["paused"]);
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "an unknown release answer was taken as released");
		assert(outcome.reason instanceof ResultAcquisitionError, String(outcome.reason));
		assertEquals(outcome.reason.stage, "release-effect");
		assert(LocalRefusal.is(outcome.reason.cause, "release-unconfirmed"), String(outcome.reason.cause));
		assertEquals(outcome.reason.cause.cause, 'the session answered a release with "paused"');
		assertEquals(asks.length, 1);
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("an opening whose route was given back does not own the row it reaches", async () => {
	const current = saved();
	const acquired: string[] = [];
	const session = actionSession({
		directoryReader: () =>
			Promise.resolve({ memberRegistration: () => Promise.resolve("peer-registration"), free() {} }),
	}, {
		readBeforeSending: () => Promise.resolve(current),
		readNow: () => Promise.resolve(current),
		command: () =>
			Promise.resolve(
				fakeHandle<ManagedOperation>({ id: "receipt", result: () => Promise.resolve({ inbox: "route" }) }),
			),
		// The member opened the conversation while this command ran, so the
		// route went back and the row keeps the member's opening.
		completeResult: () => {
			const row = direct(current);
			row.closed = false;
			introduction(row).opening = "their-opening";
			return Promise.resolve();
		},
	});
	const opening = fakeHandle<ConversationOpening>({
		acquired: (id: string) => {
			acquired.push(id);
			return Promise.resolve();
		},
	});
	assertEquals((await acquireDirect(session, "directory", "bob", undefined, opening))?.id, "saved");
	assertEquals(acquired, []);
});
