// Draft writes preserve newer edits, original receipts and exact authority across
// contention, and a write a lost link cut off is written again at once, even
// while held access is still being reached over the new link. A write
// never replaces a draft another tab wrote since this one staged, and one the
// session refused waits for the person.
import "./managed_drafts/room.ts";
import { initializeApplication } from "../support/application.ts";
import { browserFailure, refusalCode } from "../support/browser_failure.ts";
import { assert, assertEquals } from "../assert.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { type ManagedOperation, WorkspaceConflict } from "../../web/ui/session/managed/operation.ts";
import { canTryNow, handleOf, unreachedView } from "../../web/ui/session/managed/held_control.ts";
import {
	everyReached,
	FakeClock,
	linkedWorkspace,
	relinking,
	request,
	savedHandle,
	timedOutOutcome,
} from "../support/managed_link.ts";
import { settle, until, within } from "../support/wait.ts";
import { refusalText } from "../../lib/text/failure.ts";
import { LINK_WAIT_MS } from "../../web/ui/session/managed/link.ts";
import { fakeHandle } from "../support/managed_link.ts";

await initializeApplication();

/** A workspace holding the conversation "dm" whose draft is `draft`. */
function withDm(draft: string) {
	const accepted = snapshot();
	accepted.intent.conversations.push({
		kind: "direct",
		id: "dm",
		directory: "dir",
		peer: "bo",
		access: null,
		closed: false,
		draft,
	});
	return accepted;
}

/** Draft writes over the link `name`, each logged to `written` and answered with `status`. */
function writes(name: string, written: string[], status: "committed" | "refused") {
	return {
		prepareCommand: (_operation: string, _revision: string, _name: string, args: string[]) => {
			written.push(`${name}:${args[1]}`);
			return Promise.resolve({
				submit: () => Promise.resolve({ status, reason: "the conversation is closed" }),
				status: () => Promise.resolve(status),
				result: () => Promise.resolve(null),
				free() {},
			});
		},
	};
}

Deno.test("managed draft acknowledgment cannot erase a newer local edit", async () => {
	const accepted = snapshot();
	accepted.intent.conversations.push({
		kind: "direct",
		id: "dm",
		directory: "dir",
		peer: "peer",
		access: null,
		closed: false,
		draft: "old",
	});
	const session = viewer({ snapshot: () => Promise.resolve(accepted) });
	await session.readNow();
	const first = deferred<void>();
	const entered = deferred<void>();
	const values: string[] = [];
	session.command = async (_name, args = []) => {
		values.push(args[1]);
		entered.resolve();
		if (values.length === 1) await first.promise;
		return fakeHandle<ManagedOperation>({ result: () => Promise.resolve(null) });
	};
	session.finish = () => {};
	session.drafts.stage("dm", "first");
	const writing = session.drafts.flush("dm");
	await entered.promise;
	session.drafts.stage("dm", "latest");
	assertEquals(session.drafts.value("dm", "old"), "latest");
	first.resolve();
	await writing;
	assertEquals(values, ["first", "latest"]);
	assertEquals(session.drafts.value("dm", "accepted"), "accepted");
	await session.close();
});

Deno.test("managed draft completion needs no recovery permission before sending a newer edit", async () => {
	const accepted = snapshot();
	accepted.intent.conversations.push({
		kind: "direct",
		id: "dm",
		directory: "dir",
		peer: "peer",
		access: null,
		closed: false,
		draft: "old",
	});
	const writes: string[] = [];
	let submissions = 0;
	let recovered = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(accepted),
		prepareCommand: (_operation: string, _revision: string, name: string, args: string[]) => {
			assertEquals(name, "setDraft");
			writes.push(args[1]);
			return Promise.resolve({
				// The session takes each write, the first among them, whose answer is lost.
				submit: () => {
					const row = accepted.intent.conversations.find((conversation) => conversation.id === "dm");
					if (row != null) row.draft = args[1];
					return ++submissions === 1
						? Promise.resolve(timedOutOutcome())
						: Promise.resolve({ status: "committed" });
				},
				status: () => Promise.resolve("committed"),
				result: () => Promise.resolve(null),
				free() {},
			});
		},
		recoverEffect: () => {
			recovered++;
			return Promise.reject(new Error("glowcap error -12: Denied"));
		},
	});
	await session.readNow();
	session.drafts.stage("dm", "first");
	const refused = await Promise.allSettled([session.drafts.flush("dm")]);
	assertEquals(refused[0].status, "rejected");
	assertEquals(session.pending.length, 1);
	session.drafts.stage("dm", "latest");
	await session.drafts.flush("dm");
	assertEquals(recovered, 0);
	assertEquals(writes, ["first", "latest"], "lost acknowledgment cannot prepare the first write again");
	assertEquals(session.pending, []);
	await session.close();
});

for (const changed of ["unrelated", "draft", "authority", "repeated"] as const) {
	Deno.test(`managed draft conflict rebases only unchanged intent: ${changed}`, async () => {
		const accepted = snapshot();
		const conversation = {
			kind: "direct" as const,
			id: "dm",
			directory: "dir",
			peer: "peer",
			access: "original",
			closed: false,
			draft: "old",
		};
		accepted.intent.conversations.push(conversation);
		let submissions = 0;
		const session = viewer({
			snapshot: () => Promise.resolve(accepted),
			prepareCommand: () =>
				Promise.resolve({
					submit: () => {
						submissions++;
						if (submissions === 1 || changed === "repeated") {
							accepted.revision = String(Number(accepted.revision) + 1);
							if (changed === "draft") conversation.draft = "another viewer's edit";
							if (changed === "authority") conversation.access = "replacement";
							return Promise.resolve({ status: "conflict" });
						}
						return Promise.resolve({ status: "committed" });
					},
					status: () => Promise.resolve("committed"),
					result: () => Promise.resolve(null),
					free() {},
				}),
		});
		await session.readNow();
		session.drafts.stage("dm", "my edit");
		const [outcome] = await Promise.allSettled([session.drafts.flush("dm")]);
		assertEquals(outcome.status, changed === "unrelated" ? "fulfilled" : "rejected");
		assertEquals(submissions, changed === "unrelated" || changed === "repeated" ? 2 : 1);
		assertEquals(session.pending, [], "a conflict proves absence of admission");
		assertEquals(session.drafts.value("dm", "accepted"), changed === "unrelated" ? "accepted" : "my edit");
		await session.close();
	});
}

Deno.test("a slow draft leaves another conversation free to settle", async () => {
	const accepted = snapshot();
	for (const id of ["a", "b"]) {
		accepted.intent.conversations.push({
			kind: "direct",
			id,
			directory: "dir",
			peer: id,
			access: null,
			closed: false,
			draft: "",
		});
	}
	const first = deferred<void>();
	const entered = deferred<void>();
	const completed: string[] = [];
	const session = viewer({ snapshot: () => Promise.resolve(accepted) });
	await session.readNow();
	session.command = async (_name, args = []) => {
		if (args[0] === "a") {
			entered.resolve();
			await first.promise;
		}
		completed.push(args[0]);
		return fakeHandle<ManagedOperation>({ result: () => Promise.resolve(null) });
	};
	session.finish = () => {};
	session.drafts.stage("a", "slow");
	const a = session.drafts.flush("a");
	await entered.promise;
	session.drafts.stage("b", "independent");
	await session.drafts.flush("b");
	assertEquals(completed, ["b"]);
	first.resolve();
	await a;
	await session.close();
});

Deno.test("background draft failure keeps newer text and one persistent notice until retry", async () => {
	const accepted = snapshot();
	accepted.intent.conversations.push({
		kind: "direct",
		id: "dm",
		directory: "dir",
		peer: "bo",
		access: null,
		closed: false,
		draft: "",
	});
	const session = viewer({ snapshot: () => Promise.resolve(accepted) });
	await session.readNow();
	let attempts = 0;
	session.command = () => {
		attempts++;
		return Promise.reject(new Error("storage unavailable"));
	};
	session.drafts.stage("dm", "first");
	await Promise.allSettled([session.drafts.flush("dm")]);
	for (let i = 0; i < 50; i++) {
		session.drafts.stage("dm", `latest ${i}`);
		session.drafts.sync("dm");
	}
	assertEquals(attempts, 1);
	assertEquals(session.drafts.value("dm", ""), "latest 49");
	assertEquals(session.drafts.failure("dm")?.text.includes("storage unavailable"), true);
	session.command = () => Promise.resolve(fakeHandle<ManagedOperation>({ result: () => Promise.resolve(null) }));
	session.finish = () => {};
	await session.drafts.flush("dm");
	assertEquals(session.drafts.failure("dm"), undefined);
	await session.close();
});

/** A page whose draft write is cut off with the first link, and the session
 * holds no record of it over the second. `landed` says whether the lost write
 * reached the session anyway, so the second link reads the draft it wrote.
 * `typed` is what the person typed after that write left, if anything. */
async function lostDraftWrite(landed: boolean, typed: string | null = null) {
	const written: string[] = [];
	const first = linkedWorkspace("first", [], {
		snapshot: () => Promise.resolve(withDm("")),
		prepareCommand: (_operation: string, _revision: string, _name: string, args: string[]) => {
			written.push(`first:${args[1]}`);
			return Promise.resolve(request(() => first.submitLost(), () => first.park<string>()));
		},
	});
	const second = linkedWorkspace("second", []);
	let conflicts = landed ? 1 : 0;
	Object.assign(second.workspace, {
		snapshot: () => Promise.resolve(withDm(landed ? "kept" : "")),
		recoverEffect: () => Promise.resolve(null),
		prepareCommand: (_operation: string, _revision: string, _name: string, args: string[]) => {
			written.push(`second:${args[1]}`);
			// The session fences the write on the draft it was prepared over, so the
			// first one prepared before the page read what landed conflicts.
			const status = conflicts-- > 0 ? "conflict" : "committed";
			return Promise.resolve({
				submit: () => Promise.resolve({ status }),
				status: () => Promise.resolve("committed"),
				result: () => Promise.resolve(null),
				free() {},
			});
		},
	});
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	session.drafts.stage("dm", "kept");
	const flushing = session.drafts.flush("dm").then(() => null, (error: unknown) => error);
	await settle();
	if (typed != null) session.drafts.stage("dm", typed);
	first.lose();
	const failed = await within(flushing, "the draft to be written again");
	return { session, failed, written };
}

Deno.test("a draft write the session holds no record of after a lost link is written again at once", async () => {
	const { session, failed, written } = await lostDraftWrite(false);
	assertEquals(failed, null, "the draft is saved over the next link");
	assertEquals(written, ["first:kept", "second:kept"]);
	assertEquals(session.drafts.failure("dm"), undefined);
	assertEquals(session.drafts.value("dm", "accepted"), "accepted", "the session holds the text now");
	await session.close();
});

Deno.test("a lost draft write that reached the session anyway counts as this tab's own, so the next write goes through", async () => {
	// The text typed since differs from the one that landed, so only the lost
	// write's record lets the next write replace it.
	const { session, failed, written } = await lostDraftWrite(true, "kept, and more");
	assertEquals(failed, null, "the draft the lost write left is not a competing one");
	assertEquals(written, ["first:kept", "second:kept, and more", "second:kept, and more"]);
	assertEquals(session.drafts.failure("dm"), undefined);
	await session.close();
});

Deno.test("a draft write the session refused is not written again when the link comes back", async () => {
	const written: string[] = [];
	const first = linkedWorkspace("first", [], {
		snapshot: () => Promise.resolve(withDm("")),
		...writes("first", written, "refused"),
	});
	const second = linkedWorkspace("second", [], {
		snapshot: () => Promise.resolve(withDm("")),
		...writes("second", written, "committed"),
	});
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	session.drafts.stage("dm", "mine");
	await Promise.allSettled([session.drafts.flush("dm")]);
	assert(session.drafts.failure("dm") != null, "the refusal is shown");
	first.lose();
	await settle();
	assert(first.state.freed === 1 && session.link?.live === true, "the new link");
	await settle();
	assertEquals(written, ["first:mine"], "a refusal waits for the person");
	assertEquals(session.drafts.value("dm", ""), "mine");
	await session.close();
});

Deno.test("a draft held back while the link was refused is written once Try now brings the link back", async () => {
	const written: string[] = [];
	const first = linkedWorkspace("first", [], { snapshot: () => Promise.resolve(withDm("")) });
	const second = linkedWorkspace("second", [], {
		snapshot: () => Promise.resolve(withDm("")),
		...writes("second", written, "committed"),
	});
	let dials = 0;
	const session = viewer(
		first.workspace,
		undefined,
		{
			// The first dial is refused, and the one a person asks for reaches the session.
			relink: () =>
				++dials === 1
					? Promise.reject(browserFailure(null, "Saved workspace", "session-capability-gone"))
					: Promise.resolve(second.workspace),
		},
		false,
		new FakeClock(),
	);
	await session.start();
	first.lose();
	await settle();
	assertEquals(session.link?.state.kind, "refused");
	session.drafts.stage("dm", "mine");
	await Promise.allSettled([session.drafts.flush("dm")]);
	assert(session.drafts.failure("dm") != null, "the refusal is shown on the draft");
	session.link?.tryNow();
	await settle();
	await settle();
	assertEquals([session.link?.live, written], [true, ["second:mine"]], "the draft written without a press");
	assertEquals(session.drafts.failure("dm"), undefined, "the draft's failure clears");
	await session.close();
});

Deno.test("a held draft is written over the new link while a saved access there has not answered, which then ends unreached with Try now", async () => {
	const written: string[] = [];
	const freed: string[] = [];
	const first = linkedWorkspace("first", [], { snapshot: () => Promise.resolve(withDm("")) });
	const second = linkedWorkspace("second", [], {
		snapshot: () => Promise.resolve(withDm("")),
		...writes("second", written, "committed"),
	});
	// The Rust dial of a saved access gives up within a request's time.
	const silent = Promise.withResolvers<unknown>();
	const answers: Record<string, (() => Promise<unknown>)[]> = {
		silent: [
			() => Promise.resolve(savedHandle(freed, "silent")),
			() => silent.promise,
			() => Promise.resolve(savedHandle(freed, "silent again")),
		],
		quick: [
			() => Promise.resolve(savedHandle(freed, "quick")),
			() => Promise.resolve(savedHandle(freed, "quick again")),
		],
	};
	let dials = 0;
	const session = viewer(
		first.workspace,
		undefined,
		{
			savedControl: (id: string) =>
				answers[id]?.shift()?.() ?? Promise.reject(new Error("restored once too often")),
			// The first dial is refused, so the draft is held back until Try now.
			relink: () =>
				++dials === 1
					? Promise.reject(browserFailure(null, "Saved workspace", "session-capability-gone"))
					: Promise.resolve(second.workspace),
		},
		false,
		new FakeClock(),
	);
	await session.start();
	await session.management.restore(["silent", "quick"], everyReached);
	let moved = false;
	session.onRelink(() => moved = true);
	first.lose();
	await settle();
	session.drafts.stage("dm", "mine");
	await Promise.allSettled([session.drafts.flush("dm")]);
	session.link?.tryNow();
	await until(() => written.length === 1, "the held draft to be written");
	const [silentRow, quickRow] = session.management.held;
	assertEquals(
		[written, moved, silentRow.state.kind, answers.silent.length],
		[["second:mine"], true, "reached", 1],
		"the draft and the page's other steps go on while one access has not answered",
	);
	await until(() => Reflect.get(handleOf(quickRow) ?? {}, "name") === "quick again", "the other access");
	silent.reject(browserFailure(null, "Saved management connection timed out", "session-unreachable"));
	await until(() => silentRow.state.kind === "unreached", "the silent access to end unreached");
	assert(canTryNow(silentRow), "the row offers Try now");
	assertEquals(
		silentRow.state.kind === "reached" ? null : unreachedView(silentRow.state.failure).summary,
		"Rooms couldn't reach this access's session.",
	);
	await within(session.management.reachAgain(silentRow), "Try now on the row");
	assertEquals(Reflect.get(handleOf(silentRow) ?? {}, "name"), "silent again");
	await session.close();
});

/** A page whose link is down while the person types into "dm". The next link
 * comes once `returns` settles, and reads the draft another tab wrote meanwhile. */
async function typedWhileAnotherTabWrote(returns: Promise<void>, clock: FakeClock) {
	const written: string[] = [];
	const first = linkedWorkspace("first", [], { snapshot: () => Promise.resolve(withDm("")) });
	const second = linkedWorkspace("second", [], {
		snapshot: () => Promise.resolve(withDm("the other tab's")),
		...writes("second", written, "committed"),
	});
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => returns.then(() => second.workspace) },
		false,
		clock,
	);
	await session.start();
	first.lose();
	await settle();
	session.drafts.stage("dm", "typed while away");
	const flushing = session.drafts.flush("dm").then(() => null, (error: unknown) => error);
	await settle();
	return { session, first, written, flushing };
}
const competingDraft = refusalText(new WorkspaceConflict());

Deno.test("a draft write whose reply a lost link cut off, which landed, counts as this tab's own after the next write is not sent", async () => {
	const written: string[] = [];
	const first = linkedWorkspace("first", [], {
		snapshot: () => Promise.resolve(withDm("")),
		prepareCommand: (_operation: string, _revision: string, _name: string, args: string[]) => {
			written.push(`first:${args[1]}`);
			return Promise.resolve(request(() => first.submitLost(), () => first.park<string>()));
		},
	});
	// The next link holds no record of the write, and drops as it answers.
	const second = linkedWorkspace("second", [], {
		snapshot: () => Promise.resolve(withDm("")),
		recoverEffect: () => {
			second.lose();
			return Promise.resolve(null);
		},
		...writes("second", written, "committed"),
	});
	// The lost write landed after all: the link after that reads it as the row's draft.
	const third = linkedWorkspace("third", [], {
		snapshot: () => Promise.resolve(withDm("a")),
		...writes("third", written, "committed"),
	});
	const back = deferred<void>();
	const clock = new FakeClock();
	let dials = 0;
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => ++dials === 1 ? Promise.resolve(second.workspace) : back.promise.then(() => third.workspace) },
		false,
		clock,
	);
	await session.start();
	session.drafts.stage("dm", "a");
	const flushing = session.drafts.flush("dm").then(() => null, (error: unknown) => error);
	await settle();
	first.lose();
	await settle();
	assert(dials === 1 && session.link?.live === false, "the second link to drop");
	await settle();
	clock.advance(LINK_WAIT_MS);
	const refused = await within(flushing, "the next write to be refused as not sent");
	assertEquals(refusalCode(refused), "local-not-sent");
	session.drafts.stage("dm", "ab");
	// The wait for the link outlasts the backoff, so the page is dialing again.
	assertEquals(dials, 2);
	back.resolve();
	await settle();
	assert(written.includes("third:ab"), "the draft to be written over the third link");
	await settle();
	assert(session.drafts.failure("dm") == null, "the write to be confirmed");
	assertEquals(written, ["first:a", "third:ab"]);
	await session.close();
});

Deno.test("a draft held for the link while another tab wrote its own stays here, and the other draft stays", async () => {
	const back = deferred<void>();
	const { session, written, flushing } = await typedWhileAnotherTabWrote(back.promise, new FakeClock());
	back.resolve();
	const failed = await within(flushing, "the write to meet the other draft");
	assert(failed instanceof WorkspaceConflict, String(failed));
	assertEquals(written, [], "the other tab's draft is not written over");
	assertEquals(session.drafts.failure("dm")?.text, competingDraft);
	assertEquals(session.drafts.value("dm", "the other tab's"), "typed while away");
	await session.close();
});

Deno.test("a draft the link kept from being sent, while another tab wrote its own, meets the other draft when the link returns", async () => {
	const back = deferred<void>();
	const clock = new FakeClock();
	const { session, first, written, flushing } = await typedWhileAnotherTabWrote(back.promise, clock);
	clock.advance(LINK_WAIT_MS);
	const refused = await within(flushing, "the write to be refused as not sent");
	assertEquals(refusalCode(refused), "local-not-sent");
	back.resolve();
	await settle();
	assert(first.state.freed === 1 && session.link?.live === true, "the new link");
	await settle();
	assert(session.drafts.failure("dm")?.text === competingDraft, "the write to meet the other draft");
	assertEquals(written, [], "the other tab's draft is not written over");
	assertEquals(session.drafts.value("dm", "the other tab's"), "typed while away");
	await session.close();
});

Deno.test("a held draft write whose record the session no longer holds is written again, not left to fail for good", async () => {
	const accepted = withDm("old");
	const written: string[] = [];
	const session = viewer({
		snapshot: () => Promise.resolve(accepted),
		// Another tab adopted and retired the held write, so nothing recovers it.
		recoverEffect: () => Promise.resolve(null),
		prepareCommand: (_operation: string, _revision: string, _name: string, args: string[]) => {
			written.push(args[1]);
			const first = written.length === 1;
			return Promise.resolve({
				// The first write's answer is lost, so this tab holds it.
				submit: () => first ? Promise.resolve(timedOutOutcome()) : Promise.resolve({ status: "committed" }),
				status: () => first ? Promise.reject(new Error("no such receipt")) : Promise.resolve("committed"),
				result: () => Promise.resolve(null),
				free() {},
			});
		},
	});
	await session.readNow();
	session.drafts.stage("dm", "kept");
	await Promise.allSettled([session.drafts.flush("dm")]);
	assertEquals(session.pending.length, 1, "this tab holds the write");
	await within(session.drafts.flush("dm"), "the draft to be written again");
	assertEquals(written, ["kept", "kept"]);
	assertEquals(session.drafts.failure("dm"), undefined);
	assertEquals(session.drafts.value("dm", "old"), "old", "nothing is left staged");
	await session.close();
});
