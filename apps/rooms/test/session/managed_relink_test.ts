// What a page holds when its link breaks. An acquisition the session has not
// settled ends with a coded refusal that says whether it may have gone through,
// and is never sent again. One the session committed is shown over the next
// link. Overlapping links move what the page keeps once.
import { handleOf } from "../../web/ui/session/managed/held_control.ts";
import { assert, assertEquals } from "../assert.ts";
import { settle } from "../support/wait.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import {
	backedOff,
	bindingHandle,
	closed,
	closedOutcome,
	everyReached,
	FakeClock,
	fakeHandle,
	linkedWorkspace,
	operationOf,
	relinking,
	savedHandle,
} from "../support/managed_link.ts";
import { connectionLost, LocalRefusal } from "../../lib/text/failure.ts";
import { browserFailure, refusalCode } from "../support/browser_failure.ts";
import { ConversationOpening } from "../../web/ui/session/managed/openings.ts";
import type {
	RoomsManagedIncoming,
	RoomsManagedRecoveredEffect,
} from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ActivityPage } from "../../web/ui/session/managed/model.ts";
import { FIRST_LINK } from "../../web/ui/session/managed/link_port.ts";

/** A snapshot at `revision` holding the directory the acquisitions name. */
function withDirectory(revision: string) {
	const accepted = snapshot();
	accepted.revision = revision;
	accepted.intent.directories.push({
		id: "d",
		access: "access",
		home: false,
		nick: "n",
		nickAllocation: "exact",
		standing: null,
	});
	return { snapshot: () => Promise.resolve(accepted) };
}

const KINDS: [string, string, (session: ReturnType<typeof viewer>) => Promise<unknown>][] = [
	[
		"a directory join",
		"prepareDirectory",
		(s) => s.actions.directory("d", "route", { kind: "exact", name: "n" }, false),
	],
	["a workspace acquisition", "prepareAcquisition", (s) => s.actions.replace(snapshot())],
	["a configuration import", "prepareConfigurationImport", (s) => s.actions.importState("{}")],
	["a public room", "preparePublicRoom", (s) => s.actions.publicRoom("d", "room", "publication")],
];

/** A page with an acquisition begun over a link that breaks. `submit` answers
 * its submission over the first link, and `prepared` its preparation there. */
async function across(
	prepare: string,
	begin: (session: ReturnType<typeof viewer>) => Promise<unknown>,
	first: ReturnType<typeof linkedWorkspace>,
	submit: () => Promise<unknown>,
	prepared: () => Promise<void> = () => Promise.resolve(),
	second = linkedWorkspace("second", [], withDirectory("1")),
) {
	const stats = { freedOld: 0, secondPrepared: 0 };
	Object.assign(first.workspace, {
		[prepare]: () =>
			prepared().then(() => ({
				submit,
				reprepare: () => Promise.reject(closed()),
				free() {
					stats.freedOld++;
				},
			})),
	});
	Object.assign(second.workspace, {
		[prepare]: () => {
			stats.secondPrepared++;
			return Promise.reject(new Error("nothing is prepared again over the new link"));
		},
	});
	const reported: unknown[] = [];
	const { session } = relinking(first.workspace, second.workspace, {
		report: (_source, error) => reported.push(error),
	});
	await session.start();
	const gesture = begin(session).then(() => null, (error: unknown) => error);
	return { session, stats, reported, gesture };
}

for (const [name, prepare, begin] of KINDS) {
	Deno.test(`${name} held at the break ends once the link is replaced, says so, and is not sent again`, async () => {
		const first = linkedWorkspace("first", [], withDirectory("1"));
		// Nothing settled the submission, so the page holds it for a decision.
		const { session, stats, reported, gesture } = await across(
			prepare,
			begin,
			first,
			() => Promise.resolve({ status: "uncertain", reason: "the reply never came" }),
		);
		assertEquals(refusalCode(await gesture), "local-acquisition-unknown");
		assertEquals(session.actions.pending.length, 1, "the unanswered submission is held");
		first.lose();
		await settle();
		assert(session.link?.live === true && reported.length === 1, "the held acquisition to end");
		assertEquals(reported.map(refusalCode), ["local-receipt-lost"]);
		assertEquals([session.actions.resources.acquisitions, stats.freedOld, stats.secondPrepared], [0, 1, 0]);
		await session.close();
	});
	Deno.test(`${name} whose reply the break cut off ends with its gesture, and is not sent again`, async () => {
		const first = linkedWorkspace("first", [], withDirectory("1"));
		const { session, stats, gesture } = await across(prepare, begin, first, first.submitLost);
		await settle();
		first.lose();
		assertEquals(refusalCode(await gesture), "local-receipt-lost");
		await settle();
		assert(first.state.freed === 1 && session.link?.live === true, "the new link");
		assertEquals([session.actions.resources.acquisitions, stats.freedOld, stats.secondPrepared], [0, 1, 0]);
		await session.close();
	});
	Deno.test(`${name} still being prepared at the break sent nothing, and says so`, async () => {
		const first = linkedWorkspace("first", [], withDirectory("1"));
		const { session, stats, gesture } = await across(
			prepare,
			begin,
			first,
			() => Promise.reject(new Error("a request prepared over a broken link is never submitted")),
			() => first.park(),
		);
		await settle();
		first.lose();
		assertEquals(refusalCode(await gesture), "local-not-sent");
		assertEquals([session.actions.resources.acquisitions, stats.freedOld, stats.secondPrepared], [0, 0, 0]);
		await session.close();
	});
}

for (const [name, prepare, begin] of KINDS) {
	// Rust cannot tell a request sent onto a closed connection from one whose
	// reply the close cut off: both settle uncertain (`closedOutcome`).
	Deno.test(`${name} prepared as the link broke and sent onto the closed connection says it may have gone through, once`, async () => {
		const first = linkedWorkspace("first", [], withDirectory("1"));
		const preparing = deferred<void>();
		const { session, stats, reported, gesture } = await across(
			prepare,
			begin,
			first,
			() => Promise.resolve(closedOutcome()),
			() => preparing.promise,
		);
		await settle();
		first.lose();
		preparing.resolve();
		assertEquals(refusalCode(await gesture), "local-receipt-lost");
		await settle();
		assert(first.state.freed === 1 && session.link?.live === true, "the new link");
		assertEquals(reported, [], "the gesture says it, once");
		assertEquals([session.actions.resources.acquisitions, stats.freedOld, stats.secondPrepared], [0, 1, 0]);
		await session.close();
	});
	Deno.test(`${name} the session committed is shown over the next link when the link drops under its refresh`, async () => {
		const first = linkedWorkspace("first", [], withDirectory("1"));
		const accepted = withDirectory("1").snapshot;
		const log: string[] = [];
		let committed = false;
		Object.assign(first.workspace, {
			snapshot: () => committed ? Promise.reject(closed()) : accepted(),
		});
		const second = linkedWorkspace("second", [], {
			snapshot: () => {
				log.push("second:snapshot");
				return accepted();
			},
		});
		const { session, stats, reported, gesture } = await across(
			prepare,
			begin,
			first,
			() => {
				log.push("submit");
				committed = true;
				return Promise.resolve({ status: "committed" });
			},
			undefined,
			second,
		);
		assertEquals(await gesture, null, "a committed change is never reported as unsent");
		assertEquals(reported, []);
		assertEquals(log.filter((line) => line === "submit"), ["submit"], "submitted once");
		assert(log.includes("second:snapshot"), "the next link reads what the session committed");
		assertEquals([session.actions.resources.acquisitions, stats.freedOld, stats.secondPrepared], [0, 1, 0]);
		first.lose();
		await session.close();
	});
}

Deno.test("a cancelled room opening whose cleanup loses the link twice cleans up over the third link", async () => {
	const log: string[] = [];
	const first = linkedWorkspace("first", log, withDirectory("1"));
	const second = linkedWorkspace("second", log, withDirectory("1"));
	const third = linkedWorkspace("third", log, withDirectory("1"));
	const accepted = withDirectory("1").snapshot;
	let committed = false;
	/** After the commit, the reads before the cleanup's succeed, and the
	 * cleanup's own read of the session, read number `cleanup`, drops the link. */
	const dropsCleanup = (link: ReturnType<typeof linkedWorkspace>, name: string, cleanup: number) => {
		let reads = 0;
		Object.assign(link.workspace, {
			snapshot: () => {
				if (!committed) return accepted();
				log.push(`${name}:snapshot`);
				return ++reads === cleanup ? Promise.reject(closed()) : accepted();
			},
		});
	};
	// The first link shows the commit, then its cleanup drops. The second
	// link's dial and the refresh read first, then its cleanup drops.
	dropsCleanup(first, "first", 2);
	dropsCleanup(second, "second", 3);
	Object.assign(third.workspace, {
		snapshot: () => {
			if (committed) log.push("third:snapshot");
			return accepted();
		},
	});
	/** The opening the person cancels once the session has taken the room. */
	const cancel: { opening?: ConversationOpening } = {};
	Object.assign(first.workspace, {
		preparePublicRoom: () =>
			Promise.resolve({
				submit: () => {
					log.push("submit");
					committed = true;
					cancel.opening?.abort();
					return Promise.resolve({ status: "committed" });
				},
				free() {},
			}),
	});
	const links = [second, third];
	const clock = new FakeClock();
	const session = viewer(
		first.workspace,
		undefined,
		{
			relink: () => {
				const next = links.shift();
				return next == null ? Promise.reject(closed()) : Promise.resolve(next.workspace);
			},
		},
		false,
		clock,
	);
	await session.start();
	const opening = new ConversationOpening(session);
	cancel.opening = opening;
	const gesture = session.actions.publicRoom("d", "room", "publication", opening).then(
		() => null,
		(error: unknown) => error,
	);
	await backedOff(session, clock);
	const ended = await gesture;
	assertEquals(log.filter((line) => line === "submit"), ["submit"], `submitted once: ${ended}`);
	assertEquals(
		log.filter((line) => line.endsWith(":snapshot")),
		[...Array(2).fill("first:snapshot"), ...Array(3).fill("second:snapshot"), ...Array(3).fill("third:snapshot")],
		"each link shows the commit again, and the cleanup ends over the third",
	);
	assertEquals(session.actions.resources.acquisitions, 0);
	assertEquals(links.length, 0);
	for (const link of [first, second]) link.lose();
	await session.close();
});

Deno.test("closing the page ends a committed change waiting for a link that never comes", async () => {
	const first = linkedWorkspace("first", [], withDirectory("1"));
	const accepted = withDirectory("1").snapshot;
	let committed = false;
	Object.assign(first.workspace, {
		snapshot: () => committed ? Promise.reject(closed()) : accepted(),
		prepareDirectory: () =>
			Promise.resolve({
				submit: () => {
					committed = true;
					return Promise.resolve({ status: "committed" });
				},
				free() {},
			}),
	});
	/** The dial under way, which the test fails once the page is closing. */
	const dial: { fail?: (error: Error) => void } = {};
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => new Promise<never>((_, reject) => dial.fail = reject) },
		false,
		new FakeClock(),
	);
	await session.start();
	const gesture = session.actions.directory("d", "route", { kind: "exact", name: "n" }, false).then(
		() => null,
		(error: unknown) => error,
	);
	await settle();
	assert(session.link?.state.kind === "dialing", "the dial for the lost link");
	first.lose();
	const closing = session.close();
	dial.fail?.(closed());
	await closing;
	const error = await gesture;
	assert(!(error instanceof LocalRefusal), "it never says the change was not sent");
	assert(connectionLost(error), "the gesture ends with the lost connection, as the page closes");
});

Deno.test("a link replaced while the page moves its saved access moves it once, over the newest link", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const third = linkedWorkspace("third", []);
	const freed: string[] = [];
	const gate = deferred<void>();
	const handles = [
		() => Promise.resolve(savedHandle(freed, "restored")),
		() => gate.promise.then(() => savedHandle(freed, "stale")),
		() => Promise.resolve(savedHandle(freed, "newest")),
	];
	const links = [second, third];
	let dials = 0;
	const clock = new FakeClock();
	const session = viewer(
		first.workspace,
		undefined,
		{
			savedControl: () => {
				const next = handles.shift();
				return next == null ? Promise.reject(new Error("a saved control is fetched once per link")) : next();
			},
			relink: () => {
				dials++;
				const next = links.shift();
				return next == null
					? Promise.reject(new Error("two new links at most"))
					: Promise.resolve(next.workspace);
			},
		},
		false,
		clock,
	);
	await session.start();
	await session.management.restore(["saved"], everyReached);
	first.lose();
	await settle();
	assert(dials === 1 && session.link?.live === true, "the first new link");
	second.lose();
	await backedOff(session, clock);
	await settle();
	assertEquals([dials, session.link?.live], [2, true], "the second new link");
	gate.resolve();
	await settle();
	assert(freed.includes("stale"), "the stale handle to be let go");
	await settle();
	assert(freed.includes("restored"), "the newest handle to replace the first");
	const held = session.management.held[0];
	assert(held != null, "the saved access is still held");
	assertEquals(Reflect.get(handleOf(held) ?? {}, "name"), "newest");
	assertEquals([handles.length, freed], [0, ["stale", "restored"]]);
	await session.close();
});

Deno.test("a receipt restored while its link is replaced belongs to the old link, so it moves and the new link stays live", async () => {
	const lookup = deferred<unknown>();
	const moved: string[] = [];
	/** The session's record of the pending change `kept` over the link `name`,
	 * which commits once it is taken up. */
	const record = (name: string) => {
		const dead = () => Promise.reject(closed());
		const answer = (value: unknown) => () => name === "first" ? dead() : Promise.resolve(value);
		return {
			status: name === "first" ? () => Promise.resolve("pending") : answer("committed"),
			resume: answer("committed"),
			result: answer(null),
			receive: answer(undefined),
			free() {},
		};
	};
	const first = linkedWorkspace("first", [], {
		effects: () => Promise.resolve([{ operation: "kept", status: "pending" }]),
		recoverEffect: () => lookup.promise,
	});
	const second = linkedWorkspace("second", [], {
		recoverEffect: (id: string) => {
			moved.push(id);
			return Promise.resolve(record("second"));
		},
	});
	const { session, dials, relinked } = relinking(first.workspace, second.workspace);
	const starting = session.start();
	await settle();
	first.lose();
	await relinked();
	// The lookup over the old link answers only after the new link is live.
	lookup.resolve(record("first"));
	await starting;
	const resumed = await session.resume("kept").then(() => null, (error: unknown) => error);
	assertEquals(resumed, null, "the change settles over the new link");
	assertEquals(moved, ["kept"], "the receipt is looked up again over the new link");
	assertEquals([dials(), session.link?.live], [1, true], "the old link's loss never retires the new one");
	second.lose();
	await session.close();
});

/** A page opening over `first` whose session holds the pending receipts `ids`.
 * `lookup` answers each lookup over the first link, the second link lists the
 * receipts once `listed` settles, and every call made over a released handle
 * is recorded. */
function openingWithReceipts(
	ids: string[],
	lookup: (id: string) => Promise<unknown>,
	listed: Promise<unknown> = Promise.resolve(),
) {
	const pending = () => Promise.resolve(ids.map((operation) => ({ operation, status: "pending" })));
	const lookups: Record<"first" | "second" | "afterRelease", string[]> = { first: [], second: [], afterRelease: [] };
	let released = () => false;
	const first = linkedWorkspace("first", [], {
		effects: pending,
		recoverEffect: (id: string) => {
			if (released()) lookups.afterRelease.push(id);
			lookups.first.push(id);
			return lookup(id);
		},
	});
	released = () => first.state.freed > 0;
	const second = linkedWorkspace("second", [], {
		effects: () => listed.then(pending),
		recoverEffect: (id: string) => {
			lookups.second.push(id);
			return Promise.resolve({ status: () => Promise.resolve("pending"), free() {} });
		},
	});
	return { first, second, lookups };
}

Deno.test("a link lost while the page restores its receipts is a reconnect, and the rest are restored over the new link", async () => {
	const answer = deferred<unknown>();
	const listed = deferred<void>();
	const { first, second, lookups } = openingWithReceipts(["a", "b"], () => answer.promise, listed.promise);
	const { session } = relinking(first.workspace, second.workspace);
	const starting = session.start().then(() => null, (error: unknown) => error);
	await settle();
	assert(lookups.first.length === 1, "the first lookup");
	first.lose();
	await settle();
	assert(session.link?.live === true && first.state.freed === 1, "the new link to replace the first");
	// The lookup over the released link answers after the new link is live,
	// and the old pass goes on before the new link lists anything.
	answer.resolve({ status: () => Promise.resolve("pending"), free() {} });
	assertEquals(await starting, null, "the page opens and reconnects");
	listed.resolve();
	await settle();
	assert(lookups.second.length === 2, "the receipts to be restored over the new link");
	assertEquals(lookups, { first: ["a"], second: ["a", "b"], afterRelease: [] });
	assertEquals(session.link?.live, true);
	second.lose();
	await session.close();
});

Deno.test("a receipt restored before the link was lost is not restored again over the new link", async () => {
	const { first, second, lookups } = openingWithReceipts(["a", "b"], (id) => {
		if (id === "a") return Promise.resolve({ status: () => Promise.resolve("pending"), free() {} });
		first.lose();
		return Promise.reject(closed());
	});
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	await settle();
	assert(lookups.second.length > 0, "the rest to be restored over the new link");
	await settle();
	assertEquals(lookups, { first: ["a", "b"], second: ["b"], afterRelease: [] });
	second.lose();
	await session.close();
});

Deno.test("a link lost while the page opens, then refused, shows the refusal and does not fail the open", async () => {
	const revoked = browserFailure(-12, "The saved access was revoked", "session-restoration-failed");
	const { first, lookups } = openingWithReceipts(["a"], () => {
		first.lose();
		return Promise.reject(closed());
	});
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => Promise.reject(revoked) },
		false,
		new FakeClock(),
	);
	const opened = await session.start().then(() => null, (error: unknown) => error);
	assertEquals(opened, null, "the open stands");
	await settle();
	assert(session.link?.state.kind === "refused", "the refusal");
	assertEquals([session.link?.notice, session.link?.cause, lookups.first], ["refused", revoked, ["a"]]);
	await session.close();
});

Deno.test("a receipt moved to a new link while its completion runs leaves no acquisition for a retry to submit", async () => {
	let submissions = 0;
	let freed = 0;
	const acquisition = {
		submit: () => {
			submissions++;
			return Promise.reject(closed());
		},
		free() {
			freed++;
		},
	};
	const operation = operationOf("kept", {
		prepareResultAcquisition: () => Promise.resolve(acquisition),
		free() {},
	});
	await operation.acquire(snapshot(), []).catch(() => {});
	assertEquals([submissions, operation.acquiring], [1, true], "the lost submission keeps its acquisition");
	const completing = deferred<void>();
	const completion = operation.complete(() => completing.promise);
	const next = fakeHandle<RoomsManagedRecoveredEffect>({ free() {} });
	const moving = operation.rebind(next, { generation: FIRST_LINK + 1 });
	// A retry asks for the acquisition the operation still holds, as its owner does.
	const retry = operation.acquiring ? operation.retryAcquisition().catch(() => {}) : null;
	assertEquals(retry, null, "the old link's acquisition left with its link");
	completing.resolve();
	await Promise.all([moving, completion, retry]);
	assertEquals([submissions, freed], [1, 1], "released once, never submitted again");
});

Deno.test("a receipt its own completion finishes while it moves to a new link is not resumed there", async () => {
	const operation = operationOf("kept", { free() {} });
	const completing = deferred<void>();
	// The completion's owner finishes the operation once it ends, as `completeResult` does.
	const completion = operation.complete(() => completing.promise).then(() => operation.finish());
	const next = bindingHandle<RoomsManagedRecoveredEffect>({ status: () => Promise.resolve("committed"), free() {} });
	const moving = operation.rebind(next, { generation: FIRST_LINK + 1 }).then(() => null, (error: unknown) => error);
	completing.resolve();
	await completion;
	assertEquals(refusalCode(await moving), "local-receipt-retired", "the receipt it moved to went with the finish");
});

for (const [name, prepare, begin] of KINDS) {
	Deno.test(`${name} pressed while the link is being replaced waits for the new link and is prepared there`, async () => {
		const first = linkedWorkspace("first", [], withDirectory("1"));
		const dial = deferred<unknown>();
		const prepared = new Error("prepared over the new link");
		const second = linkedWorkspace("second", [], {
			...withDirectory("1"),
			[prepare]: () => Promise.reject(prepared),
		});
		const session = viewer(first.workspace, undefined, { relink: () => dial.promise }, false, new FakeClock());
		await session.start();
		first.lose();
		await settle();
		assert(session.link?.state.kind === "dialing", "the page to dial again");
		let outcome: unknown = "pending";
		const gesture = begin(session).then(() => null, (error: unknown) => error).then((settled) => outcome = settled);
		await settle();
		assertEquals(outcome, "pending", "the press waits for the link");
		dial.resolve(second.workspace);
		await gesture;
		assertEquals(outcome, prepared);
		second.lose();
		await session.close();
	});
}

Deno.test("an arrival read over a link a new one replaced is not prepared there, and the new link stays", async () => {
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
	const reads = { snapshot: () => Promise.resolve(accepted) };
	const first = linkedWorkspace("first", [], reads);
	const { session, dials, relinked } = relinking(first.workspace, linkedWorkspace("second", [], reads).workspace);
	await session.start();
	let preparations = 0;
	// The arrival's handle holds the first link's connection, which is closed.
	const page: ActivityPage = {
		cursor: "read over the first link",
		event: {
			at: 0,
			target: { kind: "direct", id: "dm" },
			notice: { kind: "handRoom", label: "Room" },
			authority: fakeHandle<RoomsManagedIncoming>({
				prepareAcquisition: () => {
					preparations++;
					return Promise.reject(closed());
				},
			}),
		},
	};
	first.lose();
	await relinked();
	const met = await session.actions.receive(page, { generation: FIRST_LINK }).then(() => null, (error) => error);
	await settle();
	assertEquals(
		[refusalCode(met), preparations, dials(), session.link?.live],
		["local-not-sent", 0, 1, true],
	);
	await session.close();
});
