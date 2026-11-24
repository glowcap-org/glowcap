// A held access reaches its session over a connection of its own. A call
// through it that loses that connection is the access's failure: its row says
// so and offers Try now, and the page's own link is only asked whether it still
// answers. Try now reaches the access again, and an edit it sent is looked up
// under its own sequence, so the session applies it at most once.
import { assert, assertEquals } from "../assert.ts";
import {
	closed,
	editSaid,
	everyReached,
	linkedWorkspace,
	relinking,
	savedHandle,
	timedOutOutcome,
} from "../support/managed_link.ts";
import { canTryNow } from "../../web/ui/session/managed/held_control.ts";
import { settle, until } from "../support/wait.ts";
import { deferred } from "../support/managed_viewer.ts";

Deno.test("a read that loses its access's own connection leaves the row unreached with Try now, and Try now settles the uncertain edit once", async () => {
	const log: string[] = [];
	const first = linkedWorkspace("first", log);
	const second = linkedWorkspace("second", []);
	const freed: string[] = [];
	const submits: string[] = [];
	const lost = closed();
	const edit = {
		// The session did not answer in time, which leaves the edit uncertain and
		// the connection standing.
		submitOutcome: () => {
			submits.push("first");
			return Promise.resolve(timedOutOutcome());
		},
		free: () => freed.push("first edit"),
	};
	const resumed = {
		submitOutcome: () => {
			submits.push("resumed");
			return Promise.resolve({ status: "committed" });
		},
		free: () => freed.push("resumed edit"),
	};
	let describes = 0;
	const restorations = [
		() =>
			Promise.resolve(savedHandle(freed, "first control", {
				describe: () =>
					++describes === 1 ? Promise.resolve({ available: true, revision: "1" }) : Promise.reject(lost),
				prepareLabel: () => Promise.resolve(edit),
			})),
		() =>
			Promise.resolve(savedHandle(freed, "new control", {
				resumeEdit: (from: unknown) => {
					assert(from === edit, "the edit goes on with its own request");
					return resumed;
				},
			})),
	];
	const reports: unknown[] = [];
	const { session, dials } = relinking(first.workspace, second.workspace, {
		report: (_source, error) => reports.push(error),
		application: {
			savedControl: () => restorations.shift()?.() ?? Promise.reject(new Error("the access is reached twice")),
		},
	});
	const polls = () => log.filter((line) => line === "first:poll").length;
	await session.start();
	await session.management.restore(["access"], everyReached);
	const held = session.management.held[0];
	assert(held != null, "the saved access is held");
	await session.management.prepare(held, { kind: "label", label: "renamed" }, "1");
	assertEquals((await session.management.submit(held)).phase, "uncertain");
	const polled = polls();
	const [read] = await Promise.allSettled([session.management.refresh(held)]);
	assert(read.status === "rejected" && read.reason === lost, "the read says why it failed");
	const state = held.state;
	assert(state.kind === "unreached" && state.failure === lost, "the row keeps the failure");
	assert(canTryNow(held), "the row offers Try now");
	assertEquals(freed, ["first control"], "the lost handle is freed once nothing reads it");
	await settle();
	assertEquals([polls(), session.link?.live, dials()], [polled + 1, true, 0], "the page's link answers and stays");
	await session.management.reachAgain(held);
	assertEquals([held.state.kind, editSaid(held.edit), submits], ["reached", "committed", ["first", "resumed"]]);
	assertEquals(held.committed?.label, "renamed");
	assertEquals(reports, []);
	first.lose();
	await session.close();
});

Deno.test("a handle another call still reads is freed only once that call ends", async () => {
	const first = linkedWorkspace("first", []);
	const freed: string[] = [];
	const lost = closed();
	const listed = deferred<{ rows: never[]; cursor: null }>();
	let describes = 0;
	const { session } = relinking(first.workspace, linkedWorkspace("second", []).workspace, {
		application: {
			savedControl: () =>
				Promise.resolve(savedHandle(freed, "control", {
					describe: () =>
						++describes === 1 ? Promise.resolve({ available: true, revision: "1" }) : Promise.reject(lost),
					inventory: () => listed.promise,
				})),
		},
	});
	await session.start();
	await session.management.restore(["access"], everyReached);
	const held = session.management.held[0];
	assert(held != null, "the saved access is held");
	const listing = session.management.inventory(held);
	await Promise.allSettled([session.management.refresh(held)]);
	assertEquals([held.state.kind, freed], ["unreached", []], "the listing still reads the handle");
	listed.resolve({ rows: [], cursor: null });
	await listing;
	assertEquals(freed, ["control"]);
	first.lose();
	await session.close();
});

Deno.test("Try now while an edit is being sent waits for its answer before it reaches the access", async () => {
	const first = linkedWorkspace("first", []);
	const freed: string[] = [];
	const lost = closed();
	const answer = deferred<{ status: "committed" }>();
	const edit = { submitOutcome: () => answer.promise, free: () => freed.push("edit") };
	let describes = 0;
	const restorations = [
		savedHandle(freed, "first control", {
			describe: () =>
				++describes === 1 ? Promise.resolve({ available: true, revision: "1" }) : Promise.reject(lost),
			prepareLabel: () => Promise.resolve(edit),
		}),
		savedHandle(freed, "new control"),
	];
	const { session } = relinking(first.workspace, linkedWorkspace("second", []).workspace, {
		application: { savedControl: () => Promise.resolve(restorations.shift()) },
	});
	await session.start();
	await session.management.restore(["access"], everyReached);
	const held = session.management.held[0];
	assert(held != null, "the saved access is held");
	await session.management.prepare(held, { kind: "label", label: "renamed" }, "1");
	const sending = session.management.submit(held);
	await Promise.allSettled([session.management.refresh(held)]);
	const reaching = session.management.reachAgain(held);
	await settle();
	// The loss the read saw outside a turn waits for the send's turn to end.
	assertEquals([held.state.kind, freed], ["reached", []], "nothing moves while the edit is sent");
	answer.resolve({ status: "committed" });
	assertEquals(editSaid(await sending), "committed");
	await reaching;
	// The commit frees its request, and the lost handle goes once the reach replaces it.
	assertEquals([held.state.kind, editSaid(held.edit), freed], ["reached", "committed", ["edit", "first control"]]);
	first.lose();
	await session.close();
});

Deno.test("an access whose connection closed before a move held it is unreached, and Try now reaches it", async () => {
	const freed: string[] = [];
	// Rust holds a reference another process serves attached, by where it came
	// from, so one whose session closed before the move held it answers its
	// first read as a lost connection, not as a local call's failure.
	const restorations = [
		() => Promise.resolve(savedHandle(freed, "first control")),
		() => Promise.resolve(savedHandle(freed, "closed control", { describe: () => Promise.reject(closed()) })),
		() => Promise.resolve(savedHandle(freed, "new control")),
	];
	const first = linkedWorkspace("first", []);
	const reports: unknown[] = [];
	const { session, relinked } = relinking(first.workspace, linkedWorkspace("second", []).workspace, {
		report: (_source, error) => reports.push(error),
		application: {
			savedControl: () =>
				restorations.shift()?.() ?? Promise.reject(new Error("the access is reached a fourth time")),
		},
	});
	await session.start();
	await session.management.restore(["access"], everyReached);
	const held = session.management.held[0];
	assert(held != null, "the saved access is held");
	first.lose();
	await relinked();
	await until(() => reports.length === 1, "the move to say the access's read failed");
	assertEquals([held.state.kind, canTryNow(held)], ["unreached", true], "the row offers Try now");
	await session.management.reachAgain(held);
	assertEquals(
		[held.state.kind, freed],
		["reached", ["first control", "closed control"]],
		"Try now holds it over a new handle",
	);
	await session.close();
});
