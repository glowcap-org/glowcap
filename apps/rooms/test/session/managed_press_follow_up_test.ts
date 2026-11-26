// A press owns its commit and what follows it. When the link ends under a
// read that follows a commit, the press finishes over the next link and
// sends nothing twice. A read that fails for another reason is a notice and
// the press still answers its commit.
import { assert, assertEquals } from "../assert.ts";
import { settle, within } from "../support/wait.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { closed, FakeClock, linkedWorkspace, timedOutOutcome } from "../support/managed_link.ts";
import { LINK_WAIT_MS } from "../../web/ui/session/managed/link.ts";
import { initializeApplication } from "../support/application.ts";
import { withPageGlobals } from "../support/page_globals.ts";
import "../support/match_media.ts";

await initializeApplication();
const { RoomsPage } = await import("../../web/ui/page.ts");
const { managedWorkspaceActions } = await import("../../web/ui/session/managed/workspace.ts");

/** A page whose first link commits `name` and then breaks under the next
 * read. The next dial waits on `dial`. */
function committing(name: string, how: "lost link" | "unreadable" = "lost link", onResult: () => void = () => {}) {
	const current = snapshot();
	current.intent.directories.push({
		id: "dir",
		access: "old",
		nick: "ada",
		nickAllocation: "exact",
		home: true,
		standing: null,
	});
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const dial = deferred<unknown>();
	let sent = 0;
	let afterCommit = false;
	Object.assign(first.workspace, {
		snapshot: () => {
			if (!afterCommit) return Promise.resolve(current);
			// The link ends under the read that follows the commit.
			if (how === "lost link") first.lose();
			return Promise.reject(how === "lost link" ? closed() : new Error("the view cannot be read"));
		},
		prepareCommand: (id: string, _revision: string, command: string, args: string[]) => {
			assertEquals(command, name);
			return Promise.resolve({
				// The session holds the change's result, so what follows is the read.
				result: () => {
					onResult();
					return Promise.resolve(null);
				},
				adopted: () => Promise.resolve(true),
				originalIntent: () => [id, 1, command, args],
				submit: () => {
					sent++;
					afterCommit = true;
					return Promise.resolve({ status: "committed" });
				},
				status: () => Promise.resolve("committed"),
				free() {},
			});
		},
	});
	Object.assign(second.workspace, {
		recoverEffect: (id: string) =>
			Promise.resolve({
				status: () => Promise.resolve("committed"),
				resume: () => Promise.resolve("committed"),
				result: () => Promise.resolve(null),
				adopted: () => Promise.resolve(true),
				originalIntent: () => [id, 1, name, []],
				free() {},
			}),
		snapshot: () => Promise.resolve(current),
		prepareCommand: () => {
			sent++;
			return Promise.reject(new Error("a second press sent the change again"));
		},
	});
	const clock = new FakeClock();
	const session = viewer(first.workspace, undefined, { relink: () => dial.promise }, false, clock);
	return { session, dial, first, second, clock, current, sent: () => sent };
}

Deno.test("a run verb that committed finishes over the next link when the link is lost under its follow-up read", async () => {
	const f = committing("setDirectoryStanding");
	const result = await overNextLink(f, () => f.session.actions.run("setDirectoryStanding", ["dir", "away"]));
	assertEquals(result, "answered", "the press reports its commit, not a lost link");
	assertEquals(f.sent(), 1, "the change is sent once");
	assert(f.session.pending.length === 0, "nothing is left to repeat");
	await f.session.close();
});

/** How a press ended, for a log that says why. */
function said(outcome: unknown): string {
	return outcome instanceof Error ? `failed: ${outcome.message}` : String(outcome);
}

/** Press `press` over a link lost under the follow-up of its commit, and answer
 * over the next. */
async function overNextLink(f: ReturnType<typeof committing>, press: () => Promise<unknown>): Promise<string> {
	await f.session.start();
	await f.session.readNow();
	const outcome = press().then(() => "answered", said);
	await settle();
	f.clock.advance(LINK_WAIT_MS + 1);
	await settle();
	f.dial.resolve(f.second.workspace);
	return await within(outcome, "the press's answer over the next link");
}

Deno.test("applied settings reload when the link is lost under the change's follow-up read", async () => {
	await withPageGlobals(async (reloads) => {
		const f = committing("chooseConnection");
		const actions = managedWorkspaceActions(new RoomsPage(), f.session, () => Promise.resolve());
		const result = await overNextLink(f, () => actions.applySettings({ dm: "webrtc" }));
		assertEquals(result, "answered", "the committed setting is answered");
		assertEquals(reloads(), 1);
		assertEquals(f.sent(), 1, "the change is sent once");
	});
});

Deno.test("an accepted invitation answers its commit when the link is lost under the follow-up read", async () => {
	const f = committing("acceptInvitation");
	const result = await overNextLink(f, () => f.session.actions.acceptInvitation("invitation"));
	assertEquals(result, "answered", "the press reports its commit, not a lost link");
	assertEquals(f.sent(), 1, "the change is sent once");
	assertEquals(f.session.pending.length, 0, "nothing is left to repeat");
	await f.session.close();
});

Deno.test("a held acquisition that committed answers its commit when the view cannot be read", async () => {
	const current = snapshot();
	let committed = false;
	const reports: unknown[] = [];
	const session = viewer(
		linkedWorkspace("only", [], {
			snapshot: () => committed ? Promise.reject(new Error("the view cannot be read")) : Promise.resolve(current),
			prepareAcquisition: () =>
				Promise.resolve({
					submit: () => {
						committed = true;
						return Promise.resolve({ status: "committed" });
					},
					free() {},
				}),
		}).workspace,
		(_source, error) => reports.push(error),
	);
	await session.start();
	const result = await session.actions.replace(snapshot()).then(() => "answered", said);
	assertEquals(result, "answered", "the unread view is a notice, not the press's failure");
	assertEquals(session.actions.pending, [], "a committed acquisition is not held for a repeat");
	assert(reports.length > 0, "the unread view is noticed");
	await session.close();
});

Deno.test("a resumed result acquisition answers its commit when the view cannot be read", async () => {
	const current = snapshot();
	let unreadable = false;
	let submits = 0;
	const session = viewer(
		linkedWorkspace("only", [], {
			snapshot: () =>
				unreadable ? Promise.reject(new Error("the view cannot be read")) : Promise.resolve(current),
			prepareCommand: () =>
				Promise.resolve({
					submit: () => Promise.resolve({ status: "committed" }),
					status: () => Promise.resolve("committed"),
					prepareResultAcquisition: () =>
						Promise.resolve({
							submit: () =>
								Promise.resolve(submits++ === 0 ? timedOutOutcome() : { status: "committed" }),
							free() {},
						}),
					free() {},
				}),
		}).workspace,
	);
	await session.start();
	const operation = await session.command("operations", [], "op");
	await operation.acquire(snapshot(), []).catch(() => {});
	assert(operation.acquiring, "the acquisition waits for its retry");
	unreadable = true;
	const resumed = await session.resume("op").then(() => "answered", said);
	assertEquals(resumed, "answered", "the retried acquisition answers its commit");
	assertEquals(submits, 2);
	await session.close();
});
