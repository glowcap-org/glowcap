// A page attached to a session elsewhere, over a link that breaks: the page
// dials again, releases the old handles once, and moves what it holds onto the
// new link.
import { assertThrows } from "@std/assert";
import { assert, assertEquals } from "../assert.ts";
import { connectionLost } from "../../lib/text/failure.ts";
import { structuredFailure } from "../../lib/error_codes.ts";
import { settle, until, within } from "../support/wait.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import {
	attached,
	closed,
	FakeClock,
	linkedWorkspace,
	recovered,
	relinking,
	request,
} from "../support/managed_link.ts";
import { browserFailure, refusalCode } from "../support/browser_failure.ts";
import {
	BACKOFF_FIRST_MS,
	LINK_WAIT_MS,
	PROBE_BACKSTOP_MS,
	QUIET_PROBE_MS,
} from "../../web/ui/session/managed/link.ts";

Deno.test("a session this browser runs has no link", async () => {
	const session = viewer({}, undefined, {}, true);
	assertEquals(session.link, null);
	await session.close();
});

Deno.test("a broken link is replaced, the old handles are released once, and nothing is polled on the old link", async () => {
	const log: string[] = [];
	const second = linkedWorkspace("second", log);
	const { session, first, dials, log: started } = await attached([second]);
	started.length = 0;
	first.lose();
	await settle();
	assert(session.link?.live === true && dials.length === 1, "the page to dial again");
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
	await settle();
	assert(heard.length === 1, "the first delivery");
	first.lose();
	await settle();
	assert(second.reads.length > 0, "the new link to be read");
	assertEquals(second.reads[0], "run:1");
	await session.close();
});

Deno.test("an activity read that loses its connection ends the link it ran on", async () => {
	const second = linkedWorkspace("second", []);
	const { session, first, dials, reported } = await attached([second]);
	const lost = closed();
	// Only the activity read breaks. The observation's read stays parked.
	first.script.push({ reply: () => lost });
	session.onActivity((delivery) => void delivery.take());
	await settle();
	assertEquals([dials.length, session.link?.live, second.state.readers], [1, true, 1], "the page to dial again");
	assert(!reported.includes(lost), "a lost connection is the link's to say");
	first.lose();
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
	await settle();
	assert(heard.length === 1, "the first delivery");
	first.lose();
	await settle();
	assert(heard.length >= 2, "the gap");
	assertEquals(heard[1], { cursor: "new:0", gap: true });
	assertEquals(second.reads[0], "old:1", "the page offers the cursor it kept, and the session decides");
	await session.close();
});

Deno.test("a cursor the restarted session refuses as stale starts the page over as a gap, by its code", async () => {
	const first = linkedWorkspace("first", [], {}, "old");
	const second = linkedWorkspace("second", [], {}, "new");
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	const heard: { cursor: string; gap: boolean }[] = [];
	first.script.push({
		reply: () => ({ cursor: "old:1", event: null, gap: false, head: "old:1", unavailable: false }),
	});
	second.script.push({
		reply: () =>
			browserFailure(
				-12,
				"refused",
				"activity-cursor-stale",
				"The session restarted since Rooms last read its activity.",
			),
	});
	session.onActivity((delivery) => {
		const page = delivery.take();
		heard.push({ cursor: page.cursor, gap: page.gap === true });
	});
	await settle();
	assert(heard.length === 1, "the first delivery");
	first.lose();
	await settle();
	assert(heard.length >= 2, "the gap");
	assertEquals(heard[1], { cursor: "", gap: true });
	await settle();
	assert(second.reads.length >= 2, "the read from the start");
	assertEquals(second.reads.slice(0, 2), ["old:1", ""]);
	await session.close();
});

for (
	const refusal of [
		browserFailure(-12, "observation closed"),
		browserFailure(null, "Workspace observation poll", "session-request-timed-out"),
	]
) {
	Deno.test(`a probe the session answers with ${refusal.message} keeps the link and stops nothing`, async () => {
		const { session, first, dials, reported } = await attached([]);
		first.polling(() => Promise.reject(refusal));
		session.link?.wake();
		await settle();
		// A running command's watch throws the observation's failure, so none may stand.
		assertEquals(session.updatesFailure, null, "the session-wide observation failure");
		assertEquals([session.link?.state.kind, dials.length], ["live", 0], "the session answered, so nothing dials");
		assertEquals(reported, [], "the link alone reads a probe's answer");
		await session.close();
	});
}

Deno.test("a live link is probed only after start registers its observation", async () => {
	const session = viewer(linkedWorkspace("first", []).workspace, undefined, {}, false, new FakeClock());
	assertThrows(() => session.link?.wake(), Error, "only after its observation is registered");
	await session.close();
});

Deno.test("a probe whose connection closed still dials again, and reports nothing of its own", async () => {
	const second = linkedWorkspace("second", []);
	const { session, first, dials, reported } = await attached([second]);
	const lost = closed();
	first.polling(() => Promise.reject(lost));
	session.link?.wake();
	await settle();
	assert(session.link?.live === true && dials.length === 1, "the page to dial again");
	assert(!reported.includes(lost), "a lost connection is the link's to say");
	// The closed connection fails what still waits on it, as the retired session does.
	first.lose(lost);
	await session.close();
});

Deno.test("a connection that dies without closing is noticed within the quiet bound, and the page dials again", async () => {
	const second = linkedWorkspace("second", []);
	const { session, first, clock, dials, log } = await attached([second]);
	// Nothing on the old connection answers again, and nothing says it closed.
	first.polling(() => new Promise(() => {}));
	clock.advance(QUIET_PROBE_MS);
	assertEquals(
		[log.filter((line) => line === "first:poll").length, dials.length],
		[2, 0],
		"one probe, still waiting",
	);
	clock.advance(PROBE_BACKSTOP_MS);
	await settle();
	assert(session.link?.live === true && dials.length === 1, "the page to dial again");
	first.lose();
	await session.close();
});

Deno.test("a failed dial leaves the page as it was and the next one succeeds", async () => {
	const log: string[] = [];
	const second = linkedWorkspace("second", log);
	const { session, first, clock, dials } = await attached([]);
	const answers: (() => unknown)[] = [
		() => Promise.reject(closed()),
		() => Promise.resolve(second.workspace),
	];
	Object.assign(session.application, {
		relink: () => {
			dials.push({ id: "active-view", stale: null });
			return (answers.shift() ?? (() => Promise.reject(closed())))();
		},
	});
	first.lose();
	await settle();
	assert(dials.length === 1, "the first dial");
	await settle();
	assertEquals([first.state.freed, second.state.observations, session.link?.live], [0, 0, false]);
	assertEquals(clock.next, BACKOFF_FIRST_MS, "the failed dial waits before the next");
	clock.advance(BACKOFF_FIRST_MS);
	await settle();
	assert(session.link?.live === true, "the next dial to succeed");
	assertEquals([first.state.freed, second.state.observations, dials.length], [1, 1, 2]);
	await session.close();
});

Deno.test("a dial whose later steps fail closes the session it opened, so the next dial opens its own", async () => {
	const log: string[] = [];
	const first = linkedWorkspace("first", log);
	const opened = linkedWorkspace("opened", log, {
		prepareObservation: () => Promise.reject(closed()),
		retire: () => {
			log.push("opened:retire");
			return Promise.resolve();
		},
	});
	const second = linkedWorkspace("second", log);
	const dials = [opened.workspace, second.workspace];
	const clock = new FakeClock();
	const session = viewer(
		first.workspace,
		undefined,
		{
			relink: () => {
				log.push("relink");
				const next = dials.shift();
				return next == null ? Promise.reject(closed()) : Promise.resolve(next);
			},
		},
		false,
		clock,
	);
	await session.start();
	first.lose();
	await settle();
	assert(opened.state.freed === 1, "the failed dial to let go of its workspace");
	assertEquals(log.filter((line) => line === "relink" || line === "opened:retire"), ["relink", "opened:retire"]);
	clock.advance(clock.next ?? 0);
	await settle();
	assert(session.link?.live === true, "the next dial");
	assertEquals([first.state.freed, second.state.observations], [1, 1]);
	await session.close();
});

// managed_link_state_test proves the link alone settles. This proves the page
// around it frees what the late dial brings.
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
	assertEquals(second.state.retired, 1, "the late session is closed");
	assertEquals(second.state.freed, 1, "the late workspace is released, never adopted");
	assertEquals(session.link?.state.kind, "closed");
});

Deno.test("a read over the old link that fails while the dial is under way leaves the new link live", async () => {
	const first = linkedWorkspace("first", []);
	const late = deferred<unknown>();
	first.script.push({ reply: () => late.promise });
	const second = linkedWorkspace("second", []);
	const dial = deferred<unknown>();
	let dials = 0;
	const session = viewer(
		first.workspace,
		undefined,
		{
			relink: () => {
				dials++;
				return dial.promise;
			},
		},
		false,
		new FakeClock(),
	);
	await session.start();
	const stop = session.onActivity(() => {});
	await settle();
	first.lose();
	await settle();
	assertEquals(session.link?.state.kind, "dialing");
	// The old link's activity read answers its loss only now.
	late.resolve(closed());
	await settle();
	dial.resolve(second.workspace);
	await settle();
	assert(session.link?.state.kind !== "dialing", "the dial to end");
	assertEquals([session.link?.live, dials], [true, 1], "the old link's loss is not the new one's");
	stop();
	second.lose();
	await session.close();
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

Deno.test("a command waits two request bounds for the link, then is refused as not sent", async () => {
	const first = linkedWorkspace("first", []);
	const clock = new FakeClock();
	const session = viewer(first.workspace, undefined, { relink: () => new Promise(() => {}) }, false, clock);
	await session.start();
	first.lose();
	await settle();
	const sending = session.command("setDraft", ["dm", "hello"]).then(() => null, (error: unknown) => error);
	await settle();
	let settled = false;
	void sending.then(() => settled = true);
	clock.advance(LINK_WAIT_MS - 1);
	await settle();
	assertEquals(settled, false, "the command still waits just before the bound");
	clock.advance(1);
	const refused = await within(sending, "the command to be refused");
	assertEquals(refusalCode(refused), "local-not-sent");
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
	Object.assign(second.workspace, recovered("committed", recoveries));
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	let prepared = 0;
	let freedOld = 0;
	const held = Object.assign(request(() => Promise.resolve({ status: "pending" }), () => first.park<string>()), {
		free() {
			freedOld++;
		},
	});
	const sending = session.perform("gesture", () => {
		prepared++;
		return Promise.resolve(held);
	}).then(() => null, (error: unknown) => error);
	await settle();
	assertEquals(session.pending, ["gesture"]);
	first.lose();
	assertEquals(await within(sending, "the cut off send to settle"), null, "the line that landed settles as sent");
	await settle();
	assert(recoveries.length === 1 && session.link?.live === true, "the receipt to be taken up again");
	assertEquals([prepared, recoveries], [1, ["gesture"]], "one preparation, recovered by the same operation id");
	assertEquals(freedOld, 1, "the old link's receipt is released once");
	await session.close();
});

Deno.test("a send the session did not commit before the break ends with the session's refusal, never repeated", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const recoveries: string[] = [];
	Object.assign(second.workspace, recovered("unsent", recoveries));
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	let prepared = 0;
	const sending = session.perform("gesture", () => {
		prepared++;
		return Promise.resolve(request(() => Promise.resolve({ status: "pending" }), () => first.park<string>()));
	}).then(() => null, (error: unknown) => error);
	await settle();
	first.lose();
	const refused = await within(sending, "the unsent send to settle");
	assertEquals(structuredFailure(refused)?.reason, "refused", "the gesture carries the session's own refusal");
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
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	await session.typing.set("dm", "selected", true);
	const before = session.resources;
	assertEquals(before.typing, 1);
	first.lose();
	await settle();
	assert(session.link?.live === true && typed.includes("first:free"), "the link to move");
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

Deno.test("a stop lost with its link is sent again over the link that replaces it", async () => {
	const heard: string[] = [];
	const sender = (name: string, lose: boolean) => () =>
		Promise.resolve({
			set: (on: boolean) => {
				heard.push(`${name}:${on ? "start" : "stop"}`);
				return !on && lose ? Promise.reject(closed()) : Promise.resolve();
			},
			free() {},
		});
	const first = linkedWorkspace("first", [], { typingSender: sender("first", true) });
	const second = linkedWorkspace("second", [], { typingSender: sender("second", false) });
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	await session.typing.set("dm", "selected", true);
	await session.typing.set("dm", "selected", false);
	first.lose();
	await until(() => heard.includes("second:stop"), "the stop owed to be sent over the new link");
	assertEquals(heard, ["first:start", "first:stop", "second:stop"]);
	await session.close();
});

// managed_link_state_test proves the link alone stops. This proves the page
// shows the refusal, a wake dials nothing, and a send carries the refusal.
Deno.test("a refused dial stops the page for good, with the refusal's own notice", async () => {
	const first = linkedWorkspace("first", []);
	const clock = new FakeClock();
	const revoked = browserFailure(-12, "The saved access was revoked", "session-restoration-failed");
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
	await settle();
	assert(session.link?.state.kind === "refused", "the refusal");
	assertEquals([session.link?.notice, session.link?.cause, clock.waiting], ["refused", revoked, 0]);
	assertEquals(reported, [], "the notice alone says why");
	session.link?.wake();
	assertEquals(session.link?.state.kind, "refused", "a foreground or a network wake dials nothing");
	const sent = await session.command("setDraft", ["dm", "hello"]).then(() => null, (error: unknown) => error);
	assertEquals(sent, revoked, "a send says why the session refused, not to try again");
	await session.close();
});

Deno.test("a lost link is told once, by the link, and no updates-stopped notice shows while it is replaced", async () => {
	const first = linkedWorkspace("first", []);
	const dial = deferred<unknown>();
	const reported: unknown[] = [];
	const session = viewer(
		first.workspace,
		(_source, error) => reported.push(error),
		{ relink: () => dial.promise },
		false,
		new FakeClock(),
	);
	await session.start();
	const stop = session.onActivity(() => {});
	await settle();
	first.lose();
	await settle();
	assert(session.link?.state.kind === "dialing", "the page to dial again");
	await settle();
	assertEquals([session.updatesFailure, reported], [null, []], "the link's notice is the one notice");
	stop();
	const closing = session.close();
	dial.resolve(linkedWorkspace("late", []).workspace);
	await within(closing, "the page to close");
});
