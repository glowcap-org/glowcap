// What a page holds when its link breaks moves onto the new link: each held
// acquisition is prepared again or let go from the session's fresh state, and
// overlapping links move what the page keeps once.
import { assert, assertEquals } from "../assert.ts";
import { until } from "../support/wait.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { closed, FakeClock, linkedWorkspace } from "../support/managed_link.ts";

/** A snapshot at `revision` holding the directory the acquisitions name. */
function withDirectory(revision: string) {
	const accepted = snapshot();
	accepted.revision = revision;
	accepted.intent.directories.push(
		{
			id: "d",
			name: "n",
			access: null,
			source: null,
			inbox: null,
		} as unknown as typeof accepted.intent.directories[number],
	);
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

/** A page with `kind` of acquisition held over a link that broke before it landed. */
async function held(prepare: string, begin: (session: ReturnType<typeof viewer>) => Promise<unknown>, next: string) {
	const first = linkedWorkspace("first", [], withDirectory("1"));
	const second = linkedWorkspace("second", [], withDirectory(next));
	const stats = { freedOld: 0, prepared: 0, submitted: 0 };
	Object.assign(first.workspace, {
		[prepare]: () =>
			Promise.resolve({
				submit: () => Promise.reject(closed()),
				reprepare: () => Promise.reject(closed()),
				free() {
					stats.freedOld++;
				},
			}),
	});
	Object.assign(second.workspace, {
		[prepare]: () => {
			stats.prepared++;
			return Promise.resolve({
				submit: () => {
					stats.submitted++;
					return Promise.resolve({ status: "committed" });
				},
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
	await begin(session).then(() => null, (error: unknown) => error);
	assertEquals(session.actions.pending.length, 1, "the unanswered submission is held");
	assertEquals(session.idle, false, "a held acquisition is not quiet");
	first.lose();
	return { session, stats };
}

for (const [name, prepare, begin] of KINDS) {
	Deno.test(`${name} held at the break is prepared again over the new link, and lands once`, async () => {
		const { session, stats } = await held(prepare, begin, "1");
		await until(() => stats.prepared === 1 && session.link?.live === true, "the held request to move");
		await until(
			() => session.actions.resources.acquisitions === 1 && stats.freedOld === 1,
			"the old request to go",
		);
		assertEquals(session.idle, false, "the moved acquisition is still unfinished");
		const [id] = session.actions.pending;
		await session.actions.recoverAcquisition(id);
		assertEquals([stats.prepared, stats.submitted], [1, 1]);
		assertEquals([session.actions.resources.acquisitions, session.idle], [0, true]);
		await session.close();
	});
	Deno.test(`${name} held at the break is let go when the session moved on`, async () => {
		const { session, stats } = await held(prepare, begin, "2");
		await until(() => stats.freedOld === 1 && session.link?.live === true, "the old request to go");
		await until(() => session.actions.resources.acquisitions === 0, "the acquisition to be let go");
		assertEquals([stats.prepared, stats.submitted, session.idle], [0, 0, true]);
		await session.close();
	});
}

Deno.test("a link replaced while the page moves its receipts moves them once", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const third = linkedWorkspace("third", []);
	const gate = deferred<void>();
	let recoveries = 0;
	const receipt = { operation: "receipt", status: "pending" };
	Object.assign(second.workspace, { effects: () => gate.promise.then(() => [receipt]) });
	Object.assign(third.workspace, {
		effects: () => Promise.resolve([receipt]),
		recoverEffect: () => {
			recoveries++;
			return Promise.resolve({ status: () => Promise.resolve("pending"), free() {} });
		},
	});
	const links = [second, third];
	let dials = 0;
	const session = viewer(
		first.workspace,
		undefined,
		{
			relink: () => {
				dials++;
				return Promise.resolve(links.shift()!.workspace);
			},
		},
		false,
		new FakeClock(),
	);
	await session.start();
	first.lose();
	await until(() => dials === 1 && session.link?.live === true, "the first new link");
	second.lose();
	await until(() => dials === 2 && session.link?.live === true, "the second new link");
	gate.resolve();
	await until(() => session.pending.includes("receipt"), "the receipt to be taken up");
	await until(() => session.pending.length === 1, "one hold on the receipt");
	assertEquals(recoveries, 1, "the receipt is recovered once, over the newest link");
	assert(session.pending.filter((id) => id === "receipt").length === 1, "held once");
	await session.close();
});

Deno.test("a cursor the restarted session refuses as stale starts the page over as a gap, by its code", async () => {
	const first = linkedWorkspace("first", [], {}, "old");
	const second = linkedWorkspace("second", [], {}, "new");
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => Promise.resolve(second.workspace) },
		false,
		new FakeClock(),
	);
	await session.start();
	const heard: { cursor: string; gap: boolean }[] = [];
	first.script.push({
		reply: () => ({ cursor: "old:1", event: null, gap: false, head: "old:1", unavailable: false }),
	});
	second.script.push({
		reply: () =>
			Object.assign(new Error("glowcap error -12: refused"), {
				status: -12,
				reason: "refused",
				code: "activity-cursor-stale",
				detail: "The session restarted since this place in its activity was saved.",
			}),
	});
	session.onActivity((delivery) => {
		const page = delivery.take();
		heard.push({ cursor: page.cursor, gap: page.gap === true });
	});
	await until(() => heard.length === 1, "the first delivery");
	first.lose();
	await until(() => heard.length >= 2, "the gap");
	assertEquals(heard[1], { cursor: "", gap: true });
	await until(() => second.reads.length >= 2, "the read from the start");
	assertEquals(second.reads.slice(0, 2), ["old:1", ""]);
	await session.close();
});

Deno.test("a lost connection while a committed change resumes stays a lost connection", async () => {
	const { resumeEffect } = await import("../../web/ui/session/managed/recovery.ts");
	const { connectionLost } = await import("../../lib/text/failure.ts");
	const error = await resumeEffect({
		status: () => Promise.resolve("committed"),
		resume: () => Promise.reject(closed()),
	} as never, () => {}).then(() => null, (failure: unknown) => failure);
	assert(connectionLost(error), "the break is the link's to heal, not a result that needs recovery");
});
