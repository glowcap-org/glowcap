// An edit to a saved access under way when the link breaks moves with that
// access, restored over the new link. One the session may have taken is sent
// again under its own sequence, which looks it up: the session applies an edit
// at most once. One never sent moves too, and goes out once when it is sent.
// An access attached and not yet saved is attached again from its address.
// A saved access reaches its session over a connection of its own, so one that
// cannot be restored is that access's failure, and only asks whether the page's
// link still answers.
import { described, handleOf } from "../../web/ui/session/managed/held_control.ts";
import { refusalCode } from "../support/browser_failure.ts";
import { assert, assertEquals } from "../assert.ts";
import { settle, until } from "../support/wait.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import {
	backedOff,
	closed,
	closedOutcome,
	editSaid,
	everyReached,
	linkedWorkspace,
	noCeilings,
	relinking,
	savedHandle,
} from "../support/managed_link.ts";
import { connectionLost, LocalRefusal } from "../../lib/text/failure.ts";

/** A page renaming a saved access, whose link breaks once the edit is prepared,
 * or with `sent` once it is sent and its reply lost. The new link restores the
 * access once `restoring` settles, as a control that also answers `restored`,
 * and a third link restores it once more. */
async function editing(
	sent: boolean,
	restoring: Promise<void> = Promise.resolve(),
	restored: Record<string, unknown> = {},
) {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const freed: string[] = [];
	const submits: string[] = [];
	const edit = {
		submitOutcome: () => {
			submits.push("old link");
			return Promise.resolve(closedOutcome());
		},
		free: () => freed.push("old edit"),
	};
	const resumed = {
		submitOutcome: () => {
			submits.push("new link");
			return Promise.resolve({ status: "committed" });
		},
		free: () => freed.push("new edit"),
	};
	const restorations = [
		() => Promise.resolve(savedHandle(freed, "old control", { prepareLabel: () => Promise.resolve(edit) })),
		() =>
			restoring.then(() =>
				savedHandle(freed, "new control", {
					resumeEdit: (from: unknown) => {
						assert(from === edit, "the edit goes on with its own request");
						return resumed;
					},
					...restored,
				})
			),
		() => Promise.resolve(savedHandle(freed, "newest control")),
	];
	const third = linkedWorkspace("third", []);
	const reports: unknown[] = [];
	const { session, relinked, dials, clock } = relinking(first.workspace, second.workspace, {
		third: third.workspace,
		report: (_source, error) => reports.push(error),
		application: {
			savedControl: () =>
				restorations.shift()?.() ?? Promise.reject(new Error("a saved access is restored once per link")),
		},
	});
	await session.start();
	await session.management.restore(["access"], everyReached);
	const held = session.management.held[0];
	assert(held != null, "the saved access is held");
	await session.management.prepare(held, { kind: "label", label: "renamed" }, "1");
	if (sent) assertEquals(editSaid(await session.management.submit(held)), "uncertain");
	first.lose();
	await relinked();
	const moved = async () => {
		await settle();
		assert(freed.includes("old edit"), "the edit moves");
	};
	/** Replace the second link with the third. */
	const replace = async () => {
		second.lose();
		await backedOff(session, clock);
		await until(() => dials() === 2 && session.link?.live === true, "the third link");
	};
	return { session, held, freed, submits, reports, moved, replace };
}

Deno.test("an edit the session may have taken is looked up over the new link, under its own sequence", async () => {
	const { session, held, submits, reports, moved } = await editing(true);
	await moved();
	await settle();
	assert(editSaid(held.edit) === "committed", "the edit to be looked up");
	assertEquals(submits, ["old link", "new link"]);
	assertEquals(held.committed?.label, "renamed");
	assertEquals(reports, []);
	await session.close();
});

Deno.test("an edit the session may have taken is looked up even when its access cannot be described over the new link", async () => {
	const unanswered = new Error("the saved access did not describe itself in time");
	const { session, held, submits, reports, moved } = await editing(true, Promise.resolve(), {
		describe: () => Promise.reject(unanswered),
	});
	await moved();
	await until(() => reports.length === 1, "the describe to be reported");
	assertEquals([editSaid(held.edit), submits, reports], ["committed", ["old link", "new link"], [unanswered]]);
	await session.close();
});

Deno.test("an access whose describe fails after a newer link took over says nothing, and the newer link reaches it", async () => {
	const answered = deferred<void>();
	const { session, held, freed, submits, reports, moved, replace } = await editing(true, Promise.resolve(), {
		describe: () => answered.promise.then(() => Promise.reject(closed())),
	});
	await moved();
	await replace();
	answered.resolve();
	await until(() => freed.includes("new control"), "the newer link to reach the access");
	await settle();
	assertEquals([reports, submits, editSaid(held.edit)], [[], ["old link", "new link"], "committed"]);
	await session.close();
});

Deno.test("an edit prepared but never sent moves with its access, and goes out once over the new link", async () => {
	const { session, held, submits, moved } = await editing(false);
	await moved();
	assertEquals([editSaid(held.edit), submits], ["prepared", []], "the edit waits for its gesture");
	assertEquals(editSaid(await session.management.submit(held)), "committed");
	assertEquals([submits, held.committed?.label], [["new link"], "renamed"]);
	await session.close();
});

Deno.test("an edit sent again while its access is being restored waits for the move, and goes out once over the new link", async () => {
	const restoring = deferred<void>();
	const { session, held, submits, moved } = await editing(true, restoring.promise);
	const again = session.management.submit(held);
	await settle();
	assertEquals(submits, ["old link"], "nothing goes out while the access moves");
	restoring.resolve();
	await moved();
	assertEquals(editSaid(await again), "committed");
	assertEquals(submits, ["old link", "new link"]);
	await session.close();
});

Deno.test("an edit whose preparation lands after the link moved its access is refused as not sent, and sends nothing", async () => {
	const freed: string[] = [];
	const submits: string[] = [];
	const preparing = deferred<unknown>();
	const { session, held, moved } = await movingAccess(freed, {
		prepareLabel: () => preparing.promise,
	}, savedHandle(freed, "new control"));
	const prepared = session.management.prepare(held, { kind: "label", label: "renamed" }, "1");
	await moved();
	preparing.resolve({
		submitOutcome: () => {
			submits.push("old link");
			return Promise.resolve(closedOutcome());
		},
		free: () => freed.push("old request"),
	});
	const refused = await prepared.then(() => null, (error: unknown) => error);
	if (refused == null) await session.management.submit(held);
	assertEquals(
		[refusalCode(refused), submits, held.state.kind, freed],
		["local-not-sent", [], "reached", ["old control", "old request"]],
	);
	await session.close();
});

// A share's steps run in turn with the move, so a share being prepared when
// the link breaks is prepared first, then moves with its access.
Deno.test("a share whose preparation is under way when the link breaks moves once prepared, and sends nothing over the old link", async () => {
	const freed: string[] = [];
	const submits: string[] = [];
	const preparing = deferred<unknown>();
	const { session, held, moved } = await movingAccess(
		freed,
		{ prepareIssue: () => preparing.promise },
		savedHandle(freed, "new control", {
			resumeIssue: () => ({
				submitOutcome: () => {
					submits.push("new link");
					return Promise.resolve({ status: "conflict" });
				},
				free: () => freed.push("new request"),
			}),
		}),
	);
	const prepared = session.management.prepareIssue(held, [], "shared", false, 0, noCeilings);
	preparing.resolve({
		submitOutcome: () => {
			submits.push("old link");
			return Promise.resolve(closedOutcome());
		},
		free: () => freed.push("old request"),
	});
	await moved();
	await prepared;
	await session.management.submitIssue();
	assertEquals(
		[submits, held.state.kind, freed.toSorted()],
		[["new link"], "reached", ["new request", "old control", "old request"]],
	);
	await session.close();
});

/** A page holding one saved access restored as `old`, whose link then breaks
 * and restores it as `next`. `moved` breaks the link and waits for the move. */
async function movingAccess(freed: string[], old: Record<string, unknown>, next: unknown) {
	const restorations = [() => Promise.resolve(savedHandle(freed, "old control", old)), () => Promise.resolve(next)];
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const { session, relinked } = relinking(first.workspace, second.workspace, {
		application: {
			savedControl: () => restorations.shift()?.() ?? Promise.reject(new Error("restored twice")),
		},
	});
	await session.start();
	await session.management.restore(["access"], everyReached);
	const held = session.management.held[0];
	assert(held != null && described(held), "the saved access is held");
	const moved = async () => {
		first.lose();
		await relinked();
		await until(() => Reflect.get(handleOf(held) ?? {}, "name") === "new control", "the access to move");
	};
	return { session, held, moved };
}

Deno.test("a management link asked for as the link drops waits out the move, and its loss is the old handle's alone", async () => {
	const freed: string[] = [];
	const preparing = deferred<unknown>();
	const restorations = [
		() => Promise.resolve(savedHandle(freed, "old control", { prepareAttenuation: () => preparing.promise })),
		() => Promise.resolve(savedHandle(freed, "new control")),
	];
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const { session, relinked } = relinking(first.workspace, second.workspace, {
		application: { savedControl: () => restorations.shift()?.() ?? Promise.reject(new Error("restored twice")) },
	});
	await session.start();
	await session.management.restore(["access"], everyReached);
	const held = session.management.held[0];
	assert(held != null, "the saved access is held");
	const shared = session.management.share(held, {
		inspect: true,
		pause: false,
		resume: false,
		revoke: false,
		delegateControl: false,
		editCeiling: null,
		issueCeiling: null,
	});
	first.lose();
	// The share holds the access's turn, so the move onto the new link waits
	// for it to end.
	preparing.resolve({ submit: () => Promise.reject(closed()), free: () => freed.push("old request") });
	const lost = await shared.then(() => null, (error: unknown) => error);
	await relinked();
	await until(() => Reflect.get(handleOf(held) ?? {}, "name") === "new control", "the access to move");
	// The lost answer keeps its request for the next press.
	assertEquals([connectionLost(lost), held.state.kind, freed], [true, "reached", ["old control"]]);
	await session.close();
	assertEquals(freed, ["old control", "old request", "new control"], "closing lets go of the request");
});

Deno.test("an access attached but not yet saved is attached again over the new link, and saves there", async () => {
	const freed: string[] = [];
	const attached: string[] = [];
	const saves: string[] = [];
	// The page saves an access in its own storage, which no link carries.
	const first = linkedWorkspace("first", [], {
		prepareSaveControl: (_id: string, saved: unknown) => {
			saves.push(Reflect.get(Object(saved), "name"));
			return Promise.resolve({ submit: () => Promise.resolve({ status: "committed" }), free() {} });
		},
	});
	const second = linkedWorkspace("second", []);
	const handles = [savedHandle(freed, "old control"), savedHandle(freed, "new control")];
	const { session } = relinking(first.workspace, second.workspace, {
		application: {
			attachControl: (address: string) => {
				attached.push(address);
				return Promise.resolve(handles.shift());
			},
		},
	});
	await session.start();
	const held = await session.management.attach("pasted", "the pasted management link");
	first.lose();
	await settle();
	assert(first.state.freed === 1 && session.link?.live === true, "the new link");
	await settle();
	assert(freed.includes("old control"), "the access to be attached again");
	assertEquals(attached, ["the pasted management link", "the pasted management link"]);
	assertEquals(Reflect.get(handleOf(held) ?? {}, "name"), "new control");
	await session.management.save(held);
	assertEquals(
		[held.storage, saves],
		[{ kind: "saved", address: "the pasted management link" }, ["new control"]],
		"the page saves the access as the new link holds it",
	);
	second.lose();
	await session.close();
});

/** A page holding the saved accesses "down" and "up" whose link breaks once.
 * Over the new link "up" is restored, and "down" fails as a closed connection
 * does, then is reached as "newer down" when asked again. "down" holds a label
 * edit prepared over the first link. A change held over the new link waits for
 * the session's decision. */
async function restoringAround() {
	const log: string[] = [];
	// The page's own list of accesses lets a row go without any link.
	const first = linkedWorkspace("first", log, { prepareForgetControl: () => Promise.resolve(null) });
	const second = linkedWorkspace("second", log, {
		prepareAcquisition: () =>
			Promise.resolve({
				submit: () => Promise.resolve({ status: "uncertain", reason: "the reply never came" }),
				free() {},
			}),
	});
	const freed: string[] = [];
	const control = (name: string) =>
		savedHandle(freed, name, {
			prepareLabel: () => Promise.resolve({ submitOutcome: () => Promise.resolve(closedOutcome()), free() {} }),
		});
	/** Its session stays down: "down" fails once the test says so. */
	const down = deferred<void>();
	const restorations: Record<string, (() => Promise<unknown>)[]> = {
		down: [
			() => Promise.resolve(control("old down")),
			() => down.promise.then(() => Promise.reject(closed())),
			() => Promise.resolve(control("newer down")),
		],
		up: [() => Promise.resolve(control("old up")), () => Promise.resolve(control("new up"))],
	};
	const reports: unknown[] = [];
	const { session, dials, relinked } = relinking(first.workspace, second.workspace, {
		report: (_source, error) => reports.push(error),
		application: {
			savedControl: (id: string) =>
				restorations[id]?.shift()?.() ?? Promise.reject(new Error("a saved access is restored once per link")),
		},
	});
	await session.start();
	await session.management.restore(["down", "up"], everyReached);
	const [downControl] = session.management.held;
	await session.management.prepare(downControl, { kind: "label", label: "Kept" }, "1");
	first.lose();
	await relinked();
	const held = await session.actions.replace(snapshot()).then(() => null, (error: unknown) => error);
	assertEquals(refusalCode(held), "local-acquisition-unknown");
	const polls = () => log.filter((line) => line === "second:poll").length;
	const before = polls();
	return {
		session,
		second,
		failDown: () => down.resolve(),
		reports,
		dials,
		probes: () => polls() - before,
		freed,
	};
}

const heldNames = (session: ReturnType<typeof viewer>) =>
	session.management.held.map((held) => Reflect.get(handleOf(held) ?? {}, "name") ?? null);

Deno.test("a saved access whose session is down is reported alone, and a healthy link stays", async () => {
	const { session, second, failDown, reports, dials, probes, freed } = await restoringAround();
	failDown();
	await settle();
	assert(reports.length === 1, "the access to report its failure");
	await settle();
	assertEquals([session.link?.live, dials(), probes()], [true, 1, 1], "one probe, which answers, and no dial");
	assertEquals(
		heldNames(session),
		[null, "new up"],
		"the access that failed keeps its row, and the other is restored",
	);
	const [down] = session.management.held;
	assert(
		down.state.kind === "unreached" && connectionLost(down.state.failure),
		"the row says why it holds no handle",
	);
	assertEquals(freed.toSorted(), ["old down", "old up"], "no row keeps a handle over the replaced link");
	assertEquals(session.actions.pending.length, 1, "the change held over the link is untouched");
	second.lose();
	await session.close();
});

Deno.test("a change through an access the new link could not reach is not sent, and says why", async () => {
	const { session, second, failDown, reports } = await restoringAround();
	failDown();
	await settle();
	assert(reports.length === 1, "the access to report its failure");
	const [down] = session.management.held;
	const sent = await session.management.submit(down).then(() => null, (error: unknown) => error);
	assert(LocalRefusal.is(sent, "not-sent"), "nothing left, so nothing is uncertain");
	assertEquals(sent.cause, reports[0], "the access's own failure is the cause");
	assertEquals(down.edit, undefined, "the edit prepared over the replaced link ends, and was never sent");
	second.lose();
	await session.close();
});

Deno.test("an access the new link could not reach can still be removed from the list", async () => {
	const { session, second, failDown, reports } = await restoringAround();
	failDown();
	await settle();
	assert(reports.length === 1, "the access to report its failure");
	const [down] = session.management.held;
	await session.management.forget(down);
	assertEquals(heldNames(session), ["new up"]);
	second.lose();
	await session.close();
});

Deno.test("trying an access again reaches that one access over the current link", async () => {
	const { session, second, failDown, reports } = await restoringAround();
	failDown();
	await settle();
	assert(reports.length === 1, "the access to report its failure");
	const [down] = session.management.held;
	await session.management.reachAgain(down);
	assertEquals(heldNames(session), ["newer down", "new up"], "only the unreached access is reached again");
	assertEquals(down.edit, undefined, "the edit prepared over the replaced link ends, and was never sent");
	second.lose();
	await session.close();
});

Deno.test("a saved access that cannot be restored over a link that really died lets the probe find it", async () => {
	const { session, second, failDown, dials, probes } = await restoringAround();
	second.polling(() => Promise.reject(closed()));
	failDown();
	await settle();
	assert(session.link?.live === false, "the probe to find the link gone");
	assertEquals([dials(), probes()], [1, 1], "the probe moved the link, and the link waits before it dials");
	second.lose();
	await session.close();
});
