// A page attached to a session elsewhere dials it again by itself when the
// link breaks, keeps what the page holds, and says what it is doing.
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import { assert, assertEquals } from "../assert.ts";
import { connectionLost } from "../../lib/text/failure.ts";
import { until, within } from "../support/wait.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { closed, failure, FakeClock, linkedWorkspace, recovered, request, settle } from "../support/managed_link.ts";
import {
	backoff,
	BACKOFF_CEILING_MS,
	BACKOFF_FIRST_MS,
	ManagedLink,
	NOTICE_AFTER_MS,
	PROBE_MS,
	RECOVERY_WAIT_MS,
	STUCK_AFTER_MS,
} from "../../web/ui/session/managed/link.ts";

/** A link whose dials answer from the test. */
function bare() {
	const clock = new FakeClock();
	const dials: ReturnType<typeof deferred<void>>[] = [];
	const rejections: ((error: unknown) => void)[] = [];
	const reported: unknown[] = [];
	let probe: () => Promise<void> = () => Promise.resolve();
	const link = new ManagedLink({
		dial: () =>
			new Promise<void>((resolve, reject) => {
				dials.push({ promise: Promise.resolve(), resolve });
				rejections.push(reject);
			}),
		probe: () => probe(),
		changed: () => {},
		report: (error) => reported.push(error),
	}, clock);
	return {
		clock,
		link,
		dials,
		reported,
		fail: (index: number, error: unknown) => rejections[index](error),
		probing: (next: () => Promise<void>) => probe = next,
	};
}

Deno.test("the wait before each dial doubles to a ceiling and jitter only shortens it", () => {
	assertEquals(backoff(1, 0), BACKOFF_FIRST_MS);
	assertEquals(backoff(2, 0), 2 * BACKOFF_FIRST_MS);
	assertEquals(backoff(3, 0), 4 * BACKOFF_FIRST_MS);
	assertEquals(backoff(20, 0), BACKOFF_CEILING_MS);
	assertEquals(backoff(3, 1), 3_200);
});

Deno.test("a lost link dials at once, then waits out each failed dial, and a wake dials now", async () => {
	const { link, clock, dials, fail } = bare();
	link.lost(closed());
	assertEquals([link.state.kind, dials.length], ["dialing", 1]);
	fail(0, closed());
	await settle();
	assertEquals([link.state.kind, dials.length, clock.next], ["waiting", 1, 1_000]);
	clock.advance(1_000);
	assertEquals([link.state.kind, dials.length], ["dialing", 2]);
	fail(1, closed());
	await settle();
	clock.advance(1_999);
	assertEquals(dials.length, 2, "the second wait is two seconds");
	link.wake();
	assertEquals([link.state.kind, dials.length], ["dialing", 3]);
	dials[2].resolve();
	await settle();
	assertEquals([link.live, clock.waiting], [true, 0]);
});

Deno.test("only a lost connection ends a live link", () => {
	const { link, dials } = bare();
	link.lost(failure(-12, "Denied"));
	assertEquals([link.live, dials.length], [true, 0]);
});

Deno.test("a dial that ran out of time is retried, and an answered refusal is not", async () => {
	const { link, dials, fail, reported, clock } = bare();
	link.lost(closed());
	fail(0, failure(-5, "Saved workspace connection timed out", "session-unreachable"));
	await settle();
	assertEquals(link.state.kind, "waiting");
	link.wake();
	const denied = failure(-12, "The saved access was revoked", "session-restoration-failed");
	fail(1, denied);
	await settle();
	assertEquals([link.state.kind, link.notice, reported], ["refused", "refused", [denied]]);
	assertEquals(clock.waiting, 0, "a refusal runs no timer");
	link.wake();
	assertEquals([link.state.kind, dials.length], ["refused", 2], "a wake leaves a refusal alone");
	link.tryNow();
	assertEquals([link.state.kind, dials.length], ["dialing", 3], "only a person's try now dials again");
});

Deno.test("a failure inside the page is refused without an answer and offers a reload", async () => {
	const { link, fail } = bare();
	link.lost(closed());
	fail(0, new Error("the page broke"));
	await settle();
	assertEquals(link.notice, "failed");
});

Deno.test("a hidden page runs no timer and waits to be seen", async () => {
	const { link, clock, dials, fail } = bare();
	link.lost(closed());
	fail(0, closed());
	await settle();
	link.visibility(false);
	assertEquals([link.state.kind, clock.waiting], ["waiting", 0]);
	clock.advance(STUCK_AFTER_MS * 2);
	assertEquals(dials.length, 1);
	link.visibility(true);
	assertEquals(dials.length, 2);
	link.lost(closed());
	link.visibility(false);
	assertEquals(clock.waiting, 0);
});

Deno.test("a hidden page probes nothing until it is seen", () => {
	const { link, clock, probing } = bare();
	let probes = 0;
	probing(() => {
		probes++;
		return new Promise(() => {});
	});
	link.visibility(false);
	link.wake();
	assertEquals([probes, clock.waiting], [0, 0]);
	link.visibility(true);
	assertEquals([probes, clock.waiting], [1, 1]);
});

Deno.test("a device with no network waits for one, and says so", async () => {
	const { link, clock, dials, fail } = bare();
	link.connectivity(false);
	link.lost(closed());
	assertEquals([link.state.kind, dials.length], ["waiting", 0]);
	clock.time += NOTICE_AFTER_MS;
	assertEquals(link.notice, "offline");
	link.connectivity(true);
	assertEquals(dials.length, 1);
	fail(0, closed());
	await settle();
});

Deno.test("the notice names the wait only after it has lasted", async () => {
	const { link, clock, fail } = bare();
	link.lost(closed());
	fail(0, closed());
	await settle();
	assertEquals(link.notice, null);
	clock.time = NOTICE_AFTER_MS;
	assertEquals(link.notice, "reconnecting");
	clock.time = STUCK_AFTER_MS;
	assertEquals(link.notice, "stuck");
});

Deno.test("a probe that is never answered counts as a lost link", () => {
	const { link, clock, dials, probing } = bare();
	probing(() => new Promise(() => {}));
	link.wake();
	assertEquals([link.live, dials.length], [true, 0]);
	clock.advance(PROBE_MS);
	assertEquals([link.state.kind, dials.length], ["dialing", 1]);
});

Deno.test("a probe that answers keeps the link", async () => {
	const { link, clock, dials } = bare();
	link.wake();
	await settle();
	clock.advance(PROBE_MS * 2);
	assertEquals([link.live, dials.length, clock.waiting], [true, 0, 0]);
});

Deno.test("closing during a dial settles it, and the dial revives nothing", async () => {
	const { link, dials } = bare();
	link.lost(closed());
	const closing = link.close();
	dials[0].resolve();
	await within(closing, "the link to close");
	assertEquals(link.state.kind, "closed");
});

Deno.test("a session this browser runs has no link", async () => {
	const session = viewer({}, undefined, {}, true);
	assertEquals(session.link, null);
	await session.close();
});

/** A started attached session over workspace `first`, and the workspaces a dial returns in turn. */
async function attached(rest: ReturnType<typeof linkedWorkspace>[], incarnation = "run") {
	const log: string[] = [];
	const first = linkedWorkspace("first", log, {}, incarnation);
	const later = rest.map((workspace) => workspace);
	const clock = new FakeClock();
	const reported: unknown[] = [];
	const dials: { id: string; stale: unknown }[] = [];
	const session = viewer(
		first.workspace,
		(_source, error) => reported.push(error),
		{
			relink: (id: string, stale: unknown) => {
				dials.push({ id, stale });
				log.push("relink");
				const next = later.shift();
				return next == null ? Promise.reject(failure(-7, "session closing")) : Promise.resolve(next.workspace);
			},
		},
		false,
		clock,
	);
	await session.start();
	return { session, first, clock, log, reported, dials };
}

Deno.test("a broken link is replaced, the old handles are released once, and nothing is polled on the old link", async () => {
	const log: string[] = [];
	const second = linkedWorkspace("second", log);
	const { session, first, dials, log: started } = await attached([second]);
	started.length = 0;
	first.lose();
	await until(() => session.link?.live === true && dials.length === 1, "the page to dial again");
	assertEquals(dials[0].id, "active-view");
	assertEquals([first.state.freed, first.state.observationFreed], [1, 1]);
	assertEquals([second.state.observations, session.resources.observation], [1, true]);
	assert(!started.includes("first:poll"), "the old link is never polled again");
	await session.close();
	// The fake holds one object as both workspace and custody, so close frees it a second time.
	assertEquals([first.state.freed, first.state.observationFreed], [2, 1], "released exactly once");
	assertEquals(second.state.observationFreed, 1);
});

Deno.test("the page keeps its activity cursor across the link and reads on from it", async () => {
	const log: string[] = [];
	const second = linkedWorkspace("second", log);
	const { session, first } = await attached([second]);
	const heard: string[] = [];
	first.script.push({
		reply: () => ({ cursor: "run:1", event: null, gap: false, head: "run:1", unavailable: false }),
	});
	session.onActivity((delivery) => {
		heard.push(delivery.take().cursor);
	});
	await until(() => heard.length === 1, "the first delivery");
	first.lose();
	await until(() => second.reads.length > 0, "the new link to be read");
	assertEquals(second.reads[0], "run:1");
	await session.close();
});

Deno.test("a cursor from before the session restarted is answered as a gap and read on from there", async () => {
	const log: string[] = [];
	const second = linkedWorkspace("second", log, {}, "new");
	const { session, first } = await attached([second], "old");
	const heard: { cursor: string; gap: boolean }[] = [];
	first.script.push({
		reply: () => ({ cursor: "old:1", event: null, gap: false, head: "old:1", unavailable: false }),
	});
	// The restarted session itself says the cursor is from before it ran.
	second.script.push({
		reply: () => ({ cursor: "new:0", event: null, gap: true, head: "new:4", unavailable: false }),
	});
	session.onActivity((delivery) => {
		const page = delivery.take();
		heard.push({ cursor: page.cursor, gap: page.gap === true });
	});
	await until(() => heard.length === 1, "the first delivery");
	first.lose();
	await until(() => heard.length >= 2, "the gap");
	assertEquals(heard[1], { cursor: "new:0", gap: true });
	assertEquals(second.reads[0], "old:1", "the page offers the cursor it kept, and the session decides");
	await session.close();
});

Deno.test("a failed dial leaves the page as it was and the next one succeeds", async () => {
	const log: string[] = [];
	const second = linkedWorkspace("second", log);
	const { session, first, clock, dials } = await attached([]);
	const answers: (() => unknown)[] = [
		() => Promise.reject(failure(-7, "session closing")),
		() => Promise.resolve(second.workspace),
	];
	Object.assign(session.application, {
		relink: () => {
			dials.push({ id: "active-view", stale: null });
			return (answers.shift() ?? (() => Promise.reject(closed())))();
		},
	});
	first.lose();
	await until(() => dials.length === 1, "the first dial");
	await settle();
	assertEquals([first.state.freed, second.state.observations, session.link?.live], [0, 0, false]);
	assertEquals(clock.next, BACKOFF_FIRST_MS, "the failed dial waits before the next");
	clock.advance(BACKOFF_FIRST_MS);
	await until(() => session.link?.live === true, "the next dial to succeed");
	assertEquals([first.state.freed, second.state.observations, dials.length], [1, 1, 2]);
	await session.close();
});

Deno.test("close during a dial settles and no dial resolves into a closed page", async () => {
	const first = linkedWorkspace("first", []);
	const dial = deferred<unknown>();
	const second = linkedWorkspace("second", []);
	const session = viewer(first.workspace, undefined, { relink: () => dial.promise }, false, new FakeClock());
	await session.start();
	first.lose();
	await settle();
	assertEquals(session.link?.state.kind, "dialing");
	const closing = session.close();
	dial.resolve(second.workspace);
	await within(closing, "the page to close");
	assertEquals(second.state.freed, 1, "the late workspace is released, never adopted");
	assertEquals(session.link?.state.kind, "closed");
});

Deno.test("a command sent while the link is down goes out once, after the link returns", async () => {
	const log: string[] = [];
	const second = linkedWorkspace("second", log);
	const gate = deferred<unknown>();
	const first = linkedWorkspace("first", log);
	const prepared: string[] = [];
	const session = viewer(
		first.workspace,
		undefined,
		{
			relink: () => gate.promise.then(() => second.workspace),
		},
		false,
		new FakeClock(),
	);
	Object.assign(second.workspace, {
		prepareCommand: (operation: string) => {
			prepared.push(operation);
			return Promise.resolve({
				submit: () => Promise.resolve({ status: "committed" }),
				status: () => Promise.resolve("committed"),
				result: () => Promise.resolve(null),
				free() {},
			});
		},
	});
	await session.start();
	first.lose();
	await settle();
	const sending = session.command("setDraft", ["dm", "hello"]);
	await settle();
	assertEquals(prepared, [], "nothing goes out on a link that is gone");
	gate.resolve(null);
	await within(sending, "the command to go out");
	assertEquals(prepared.length, 1);
	await session.close();
});

Deno.test("a command still waiting after the request bound is refused as not sent", async () => {
	const first = linkedWorkspace("first", []);
	const clock = new FakeClock();
	const session = viewer(first.workspace, undefined, { relink: () => new Promise(() => {}) }, false, clock);
	await session.start();
	first.lose();
	await settle();
	const sending = session.command("setDraft", ["dm", "hello"]).then(() => null, (error: unknown) => error);
	await settle();
	clock.advance(RECOVERY_WAIT_MS);
	const refused = await within(sending, "the command to be refused");
	assertEquals((refused as { code?: unknown }).code, "local-not-sent");
	session.link?.close();
});

Deno.test("a draft typed while the link is down is kept and written once after it returns", async () => {
	const withDm = () => {
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
		return { snapshot: () => Promise.resolve(accepted) };
	};
	const first = linkedWorkspace("first", [], withDm());
	const second = linkedWorkspace("second", [], withDm());
	const gate = deferred<null>();
	const written: string[] = [];
	Object.assign(second.workspace, {
		prepareCommand: (_operation: string, _revision: string, name: string, args: string[]) => {
			assertEquals(name, "setDraft");
			written.push(args[1]);
			return Promise.resolve({
				submit: () => Promise.resolve({ status: "committed" }),
				status: () => Promise.resolve("committed"),
				result: () => Promise.resolve(null),
				free() {},
			});
		},
	});
	const session = viewer(
		first.workspace,
		undefined,
		{
			relink: () => gate.promise.then(() => second.workspace),
			close: () => {
				first.lose();
				second.lose();
				return Promise.resolve();
			},
		},
		false,
		new FakeClock(),
	);
	await session.start();
	first.lose();
	await settle();
	session.drafts.stage("dm", "typed while away");
	const flushing = session.drafts.flush("dm");
	await settle();
	assertEquals(written, []);
	assertEquals(session.drafts.value("dm", "accepted"), "typed while away");
	gate.resolve(null);
	await within(flushing, "the draft to be written");
	assertEquals(written, ["typed while away"]);
	await session.close();
});

Deno.test("a command admitted before the link broke is taken up again by its operation id, and prepared once", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const recoveries: string[] = [];
	Object.assign(second.workspace, {
		recoverEffect: (id: string) => {
			recoveries.push(id);
			return Promise.resolve({
				status: () => Promise.resolve("committed"),
				resume: () => Promise.resolve("committed"),
				result: () => Promise.resolve(null),
				free() {},
			});
		},
	});
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => Promise.resolve(second.workspace) },
		false,
		new FakeClock(),
	);
	await session.start();
	let prepared = 0;
	let freedOld = 0;
	const request = {
		submit: () => Promise.resolve({ status: "pending" }),
		status: () => first.park<string>(),
		free() {
			freedOld++;
		},
	} as unknown as RoomsManagedCommand;
	const sending = session.perform("gesture", () => {
		prepared++;
		return Promise.resolve(request);
	}).then(() => null, (error: unknown) => error);
	await settle();
	assertEquals(session.pending, ["gesture"]);
	first.lose();
	assertEquals(await within(sending, "the cut off send to settle"), null, "the line that landed settles as sent");
	await until(() => recoveries.length === 1 && session.link?.live === true, "the receipt to be taken up again");
	assertEquals([prepared, recoveries], [1, ["gesture"]], "one preparation, recovered by the same operation id");
	assertEquals(freedOld, 1, "the old link's receipt is released once");
	await session.close();
});

Deno.test("a send whose admission is cut off by the break settles from the session's record, once", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const recoveries: string[] = [];
	Object.assign(second.workspace, recovered("committed", recoveries));
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => Promise.resolve(second.workspace) },
		false,
		new FakeClock(),
	);
	await session.start();
	let prepared = 0;
	const sending = session.perform("gesture", () => {
		prepared++;
		return Promise.resolve(request(() => first.park(), () => first.park<string>()));
	}).then(() => null, (error: unknown) => error);
	await settle();
	first.lose();
	assertEquals(await within(sending, "the cut off admission to settle"), null);
	assertEquals([prepared, recoveries], [1, ["gesture"]], "prepared once, and read back by its operation id");
	await session.close();
});

Deno.test("a send the session did not commit before the break is refused as unsent, never repeated", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const recoveries: string[] = [];
	Object.assign(second.workspace, recovered("unsent", recoveries));
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => Promise.resolve(second.workspace) },
		false,
		new FakeClock(),
	);
	await session.start();
	let prepared = 0;
	const sending = session.perform("gesture", () => {
		prepared++;
		return Promise.resolve(request(() => Promise.resolve({ status: "pending" }), () => first.park<string>()));
	}).then(() => null, (error: unknown) => error);
	await settle();
	first.lose();
	const refused = await within(sending, "the unsent send to settle");
	assert(refused != null, "the gesture reports that it was not sent");
	assertEquals(connectionLost(refused), false, "and says so as itself, not as a lost connection");
	assertEquals(prepared, 1);
	await session.close();
});

Deno.test("everything held over the link moves with it, and a handle closes only once", async () => {
	const typed: string[] = [];
	const sender = (name: string) => () => {
		typed.push(`${name}:open`);
		return Promise.resolve({
			set: () => Promise.resolve(),
			free() {
				typed.push(`${name}:free`);
			},
		});
	};
	const first = linkedWorkspace("first", [], { typingSender: sender("first") });
	const second = linkedWorkspace("second", [], { typingSender: sender("second") });
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => Promise.resolve(second.workspace) },
		false,
		new FakeClock(),
	);
	await session.start();
	await session.typing.set("dm", "selected", true);
	const before = session.resources;
	assertEquals(before.typing, 1);
	first.lose();
	await until(() => session.link?.live === true && typed.includes("first:free"), "the link to move");
	assertEquals(session.resources.typing, 0, "the old sender is released, and none stays on the dead link");
	await session.typing.set("dm", "selected", true);
	assertEquals(typed, ["first:open", "first:free", "second:open"]);
	assertEquals(
		{ ...session.resources, workers: 0 },
		{ ...before, workers: 0 },
		"the same handles, over the new link",
	);
	await session.close();
});

Deno.test("a refused dial stops the page for good, with the refusal's own notice", async () => {
	const first = linkedWorkspace("first", []);
	const clock = new FakeClock();
	const revoked = failure(-12, "The saved access was revoked", "session-restoration-failed");
	const reported: unknown[] = [];
	const session = viewer(
		first.workspace,
		(_source, error) => reported.push(error),
		{ relink: () => Promise.reject(revoked) },
		false,
		clock,
	);
	await session.start();
	first.lose();
	await until(() => session.link?.state.kind === "refused", "the refusal");
	assertEquals([session.link?.notice, session.link?.cause, clock.waiting], ["refused", revoked, 0]);
	session.link?.wake();
	assertEquals(session.link?.state.kind, "refused", "a foreground or a network wake dials nothing");
	const sent = await session.command("setDraft", ["dm", "hello"]).then(() => null, (error: unknown) => error);
	assertEquals(sent, revoked, "a send says why the session refused, not to try again");
	await session.close();
});

Deno.test("waiting for the link ends when it is live, refused, or has stayed down for the bound", async () => {
	const { link, clock, dials, fail } = bare();
	link.lost(closed());
	const live = link.available(null);
	const bounded = link.available(1_000);
	clock.advance(1_000);
	assertEquals(await bounded, false);
	dials[0].resolve();
	assertEquals(await live, true);
	link.lost(closed());
	const refused = link.available(null);
	fail(1, failure(-12, "revoked", "session-restoration-failed"));
	assertEquals(await refused, false);
});

Deno.test("a hidden page spends no time toward a send's bound, and try now overrides a wrong offline report", async () => {
	const { link, clock, dials } = bare();
	link.lost(closed());
	link.connectivity(false);
	const bounded = link.available(1_000);
	link.visibility(false);
	assertEquals(clock.waiting, 0, "no timer runs while hidden");
	link.visibility(true);
	link.tryNow();
	assertEquals(dials.length, 1, "try now dials despite the offline report");
	dials[0].resolve();
	assertEquals(await bounded, true);
});
