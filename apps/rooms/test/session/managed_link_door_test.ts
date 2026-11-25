// What a page reads over its link to a session elsewhere goes through one
// door: a read waits while the link is replaced, a connection lost under it
// ends the link, and each panel that holds what it read reads it again over
// the new link.
/// <reference lib="dom" />
import "../support/match_media.ts";
import { assert, assertEquals } from "../assert.ts";
import { settle, until, within } from "../support/wait.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { closed, FakeClock, linkedWorkspace, relinking } from "../support/managed_link.ts";
import { browserFailure } from "../support/browser_failure.ts";
import { connectionLost } from "../../lib/text/failure.ts";
const { ManagedHistory } = await import("../../web/ui/session/managed/history.ts");
const { managedOperations } = await import("../../web/ui/session/managed/operations.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");

Deno.test("a read asked for while the link is being replaced waits for the new link and runs over it", async () => {
	const first = linkedWorkspace("first", [], { custodyRecipe: () => Promise.resolve("over the first link") });
	const second = linkedWorkspace("second", [], { custodyRecipe: () => Promise.resolve("over the new link") });
	const dial = deferred<unknown>();
	const session = viewer(first.workspace, undefined, { relink: () => dial.promise }, false, new FakeClock());
	await session.start();
	first.lose();
	await settle();
	assertEquals(session.link?.state.kind, "dialing", "the page dials again");
	let answer: string | null = null;
	const read = session.request((workspace) => workspace.custodyRecipe("{}")).then((said: string) => answer = said);
	await settle();
	assertEquals(answer, null, "the read waits while the link is being replaced");
	dial.resolve(second.workspace);
	await within(read, "the read over the new link");
	assertEquals(answer, "over the new link");
	await session.close();
});

Deno.test("what the page keeps moves once the new link is live, so a hook reads through the door at once", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", [], { custodyRecipe: () => Promise.resolve("over the new link") });
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	const heard: { live: boolean; read: Promise<string> }[] = [];
	session.onRelink(() =>
		heard.push({
			live: session.link?.live === true,
			read: session.request((workspace) => workspace.custodyRecipe("{}")),
		})
	);
	first.lose();
	await settle();
	assertEquals(heard.length, 1, "the move reaches its hooks");
	assert(heard[0].live, "the link is live before the move's hooks run");
	assertEquals(await within(heard[0].read, "the hook's read"), "over the new link");
	await session.close();
});

Deno.test("an owner that throws while the link moves is reported, and every owner after it still moves", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const reports: unknown[] = [];
	const { session, relinked } = relinking(first.workspace, second.workspace, {
		report: (_source, error) => reports.push(error),
	});
	await session.start();
	const broken = new Error("a broken owner");
	const heard: string[] = [];
	session.onRelink(() => {
		throw broken;
	});
	session.onRelink(() => heard.push("the next owner"));
	first.lose();
	await relinked();
	await settle();
	assertEquals([heard, reports], [["the next owner"], [broken]]);
	await session.close();
});

Deno.test("a connection lost under a read through the door ends the link, and the read says why", async () => {
	const first = linkedWorkspace("first", [], { custodyRecipe: () => Promise.reject(closed()) });
	const second = linkedWorkspace("second", []);
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	const [read] = await Promise.allSettled([session.request((workspace) => workspace.custodyRecipe("{}"))]);
	assert(read.status === "rejected", "the read fails");
	assert(connectionLost(read.reason), "the read says the connection was lost");
	await settle();
	assertEquals([first.state.freed, session.link?.live], [1, true], "the new link is live");
	first.lose();
	await session.close();
});

Deno.test("a read the session answers with its own unreachable line leaves the link live, and the read gets that refusal", async () => {
	// The session wrote the line, so it carries a binding status: the session
	// could not reach something itself, and this side's connection stands.
	const line = browserFailure(500, "session-unreachable: the store did not answer", "session-unreachable");
	const first = linkedWorkspace("first", [], { custodyRecipe: () => Promise.reject(line) });
	const second = linkedWorkspace("second", []);
	const { session, dials } = relinking(first.workspace, second.workspace);
	await session.start();
	const [read] = await Promise.allSettled([session.request((workspace) => workspace.custodyRecipe("{}"))]);
	assert(read.status === "rejected" && read.reason === line, "the read gets the session's own refusal");
	await settle();
	assertEquals([session.link?.live, dials(), first.state.freed], [true, 0, 0], "the link stands");
	first.lose();
	await session.close();
});

Deno.test("a connection lost under a typing level ends the link", async () => {
	const sender = { set: () => Promise.reject(closed()), free() {} };
	const first = linkedWorkspace("first", [], { typingSender: () => Promise.resolve(sender) });
	const second = linkedWorkspace("second", []);
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	await session.typing.set("dm", "selected", true);
	await settle();
	assertEquals([first.state.freed, session.link?.live], [1, true], "the new link is live");
	first.lose();
	await session.close();
});

/** History over a page attached through `first`, whose dial reaches `second`,
 * wired to the move as the page wires it. */
async function historyOver(
	first: ReturnType<typeof linkedWorkspace>,
	second: ReturnType<typeof linkedWorkspace>,
) {
	const page = new RoomsPage();
	const { session } = relinking(first.workspace, second.workspace);
	const failures: unknown[] = [];
	await session.start();
	session.permits = () => true;
	const history = new ManagedHistory(page, session, (_source, error) => failures.push(error));
	session.onRelink(() => history.relink());
	history.start();
	return { page, session, history, failures };
}

/** An archive reader named `name` whose opening is recorded in `opened` and
 * its release in `freed`. */
function archive(name: string, opened: string[], freed: string[]) {
	return () => {
		opened.push(name);
		return Promise.resolve({
			read: () => Promise.resolve({ next: "0", more: false, records: [] }),
			free: () => freed.push(name),
		});
	};
}

Deno.test("history held over a replaced link opens its reader again over the new one", async () => {
	const opened: string[] = [];
	const freed: string[] = [];
	const first = linkedWorkspace("first", [], { deviceHistory: archive("first", opened, freed) });
	const second = linkedWorkspace("second", [], { deviceHistory: archive("second", opened, freed) });
	const f = await historyOver(first, second);
	await until(() => f.page.projection.get().archiveTarget.status === "connected", "the first reader");
	const before = f.page.projection.get().archiveTarget;
	first.lose();
	await until(() => opened.includes("second"), "the reader over the new link");
	assertEquals(freed, ["first"], "the reader over the old link is released once");
	await until(() => f.page.projection.get().archiveTarget.status === "connected", "the new reader");
	// The archive shares list reads again whenever this target changes.
	assert(f.page.projection.get().archiveTarget !== before, "the archive target is set again over the new link");
	assertEquals(f.failures, []);
	await f.history.close();
	await f.session.close();
});

Deno.test("a reader that arrives after its link was replaced is freed and opened again over the new link", async () => {
	const opened: string[] = [];
	const freed: string[] = [];
	const late = Promise.withResolvers<unknown>();
	const first = linkedWorkspace("first", [], { deviceHistory: () => late.promise });
	const second = linkedWorkspace("second", [], { deviceHistory: archive("second", opened, freed) });
	const f = await historyOver(first, second);
	first.lose();
	await settle();
	assertEquals([f.session.link?.live, first.state.freed], [true, 1], "the new link is live");
	late.resolve({
		read: () => Promise.resolve({ next: "0", more: false, records: [] }),
		free: () => freed.push("late"),
	});
	await until(() => opened.includes("second"), "the reader over the new link");
	await until(() => f.page.projection.get().archiveTarget.status === "connected", "the new reader");
	assertEquals(freed, ["late"], "the late reader is freed, and the new one is held");
	assertEquals(f.failures, []);
	await f.history.close();
	await f.session.close();
});

Deno.test("history says nothing of a lost connection, which the link tells", async () => {
	const opened: string[] = [];
	const first = linkedWorkspace("first", [], { deviceHistory: () => Promise.reject(closed()) });
	const second = linkedWorkspace("second", [], { deviceHistory: archive("second", opened, []) });
	const f = await historyOver(first, second);
	await until(() => opened.includes("second"), "the reader over the new link");
	await until(() => f.page.projection.get().archiveTarget.status === "connected", "the new reader");
	assertEquals(f.failures, [], "history reports nothing of the lost connection");
	first.lose();
	await f.history.close();
	await f.session.close();
});

Deno.test("an operations pane that failed while the link was gone shows its content over the new link without a press", async () => {
	const held = () => {
		const current = snapshot();
		current.intent.operations = [{ kind: "listeners", handle: { role: "operations", key: "held" } }];
		return Promise.resolve(current);
	};
	const first = linkedWorkspace("first", [], {
		snapshot: held,
		operationsReader: () => Promise.reject(closed()),
	});
	const second = linkedWorkspace("second", [], {
		snapshot: held,
		operationsReader: () => Promise.resolve({ snapshot: () => Promise.resolve([{ id: 1 }]), free() {} }),
	});
	const page = new RoomsPage();
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	const operations = managedOperations(page, session);
	const [read] = await Promise.allSettled([operations.refreshOpsCap("listeners")]);
	assert(read.status === "rejected", "the pane's read fails with the link");
	await until(() => page.projection.get().listeners != null, "the pane to read again over the new link");
	assertEquals(page.projection.get().listeners, [{ id: 1 }]);
	first.lose();
	await session.close();
});
