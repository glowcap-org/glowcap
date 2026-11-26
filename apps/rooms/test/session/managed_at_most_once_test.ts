// A change in flight when the link to its session breaks goes out at most once.
// Over the new link the page looks the change up by its operation id. The
// session's record settles it, and with none the page never sends it again and
// says it may not have gone through. A change that was only prepared, never
// submitted, sent nothing and goes out as a first send.
import { refusalCode } from "../support/browser_failure.ts";
import { assert, assertEquals } from "../assert.ts";
import { settle, within } from "../support/wait.ts";
import { deferred, viewer } from "../support/managed_viewer.ts";
import {
	backedOff,
	closed,
	FakeClock,
	linkedWorkspace,
	recovered,
	relinking,
	request,
} from "../support/managed_link.ts";

/** A workspace's prepare that records `name`, the link it ran over, in
 * `prepared`, and makes a command the session commits. */
function preparing(name: string, prepared: string[]) {
	return {
		prepareCommand: () => {
			prepared.push(name);
			return Promise.resolve(
				request(() => Promise.resolve({ status: "committed" }), () => Promise.resolve("committed")),
			);
		},
	};
}

/** A session that records what reaches it, reached over two links in turn.
 * The first link breaks while its submit waits for an answer. */
async function breakDuringSubmit(reaches: boolean) {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const held = new Set<string>();
	let submissions = 0;
	Object.assign(second.workspace, {
		// The session's record of an operation, or null when it holds no trace.
		recoverEffect: (id: string) =>
			Promise.resolve(
				held.has(id)
					? {
						status: () => Promise.resolve("committed"),
						resume: () => Promise.resolve("committed"),
						result: () => Promise.resolve(null),
						free() {},
					}
					: null,
			),
	});
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	let preparations = 0;
	const sending = session.perform("gesture", () => {
		preparations++;
		return Promise.resolve(request(() => {
			submissions++;
			if (reaches) held.add("gesture");
			return first.submitLost();
		}, () => first.park<string>()));
	}).then(() => null, (error: unknown) => error);
	await settle();
	first.lose();
	const settled = await within(sending, "the change to settle");
	return { session, settled, preparations, submissions };
}

Deno.test("a send that reached the session but lost its reply settles with the session's record, once", async () => {
	const { session, settled, preparations, submissions } = await breakDuringSubmit(true);
	assertEquals(settled, null, "the gesture settles as the session recorded it");
	assertEquals([preparations, submissions], [1, 1]);
	await session.close();
});

Deno.test("a send the session holds no trace of is not sent again, and says it may not have gone through", async () => {
	const { session, settled, preparations, submissions } = await breakDuringSubmit(false);
	assertEquals(refusalCode(settled), "local-receipt-lost");
	assertEquals([preparations, submissions], [1, 1], "one submission in all");
	assertEquals(session.pending, [], "nothing is held for a retry");
	await session.close();
});

Deno.test("a lookup the new link drops under is made again over the next link, and settles once", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const third = linkedWorkspace("third", []);
	const lookups: string[] = [];
	Object.assign(second.workspace, {
		recoverEffect: (id: string) => {
			lookups.push(`second:${id}`);
			second.lose();
			return Promise.reject(closed());
		},
	});
	Object.assign(third.workspace, recovered("committed", lookups));
	const links = [second.workspace, third.workspace];
	const clock = new FakeClock();
	const session = viewer(
		first.workspace,
		undefined,
		{
			relink: () => {
				const next = links.shift();
				return next == null ? Promise.reject(closed()) : Promise.resolve(next);
			},
		},
		false,
		clock,
	);
	await session.start();
	const sending = session.perform(
		"gesture",
		() => Promise.resolve(request(first.submitLost, () => first.park<string>())),
	)
		.then(() => null, (error: unknown) => error);
	await settle();
	first.lose();
	await backedOff(session, clock);
	assertEquals(await within(sending, "the change to settle"), null, "the second drop is not the change's failure");
	assertEquals(lookups, ["second:gesture", "gesture"], "the lookup runs again over the next link");
	await session.close();
});

Deno.test("a change only prepared when the link broke goes out once over the new link", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	const submitted: string[] = [];
	let preparations = 0;
	const sending = session.perform("gesture", () => {
		preparations++;
		// The first preparation waits on the link that breaks, and the next
		// runs over the new one.
		if (preparations === 1) return first.park();
		return Promise.resolve(request(() => {
			submitted.push("second");
			return Promise.resolve({ status: "committed" });
		}, () => Promise.resolve("committed")));
	}).then(() => null, (error: unknown) => error);
	await settle();
	first.lose();
	assertEquals(await within(sending, "the first send to land"), null);
	assertEquals([preparations, submitted], [2, ["second"]]);
	await session.close();
});

Deno.test("a change whose link is replaced while it prepares is prepared again over the new link", async () => {
	const prepared: string[] = [];
	const first = linkedWorkspace("first", [], preparing("first", prepared));
	const second = linkedWorkspace("second", [], preparing("second", prepared));
	const { session, relinked } = relinking(first.workspace, second.workspace);
	await session.start();
	// The first preparation waits, as a send does while it reads its files.
	const reading = deferred<void>();
	let preparations = 0;
	const sending = session.perform("gesture", async (workspace) => {
		if (++preparations === 1) await reading.promise;
		return await workspace().prepareCommand("gesture", "1", "say", []);
	}).then(() => null, (error: unknown) => error);
	await settle();
	first.lose();
	await relinked();
	reading.resolve();
	assertEquals(await within(sending, "the send to land"), null);
	assertEquals([preparations, prepared], [2, ["second"]]);
	await session.close();
});

/** Two tabs over one session, which lists every receipt any tab made. Each
 * tab's first link breaks on `lose`, and its next link reaches the same
 * session. Completing a receipt retires it, as the session does. */
function sharedSession() {
	const journal = new Map<string, string>();
	const lookups: string[] = [];
	const tab = (name: string) => {
		const first = linkedWorkspace(`${name}:first`, []);
		const second = linkedWorkspace(`${name}:second`, [], {
			effects: () => Promise.resolve([...journal].map(([operation, status]) => ({ operation, status }))),
			recoverEffect: (id: string) => {
				lookups.push(`${name}:${id}`);
				const status = journal.get(id);
				return Promise.resolve(
					status == null ? null : {
						status: () => Promise.resolve(status),
						resume: () => Promise.resolve(status),
						result: () => {
							journal.delete(id);
							return Promise.resolve(null);
						},
						free() {},
					},
				);
			},
		});
		const { session } = relinking(first.workspace, second.workspace);
		return { first, session };
	};
	return { journal, lookups, tab };
}

Deno.test("a tab that relinks first leaves another tab's receipt for that tab to settle", async () => {
	const { journal, lookups, tab } = sharedSession();
	const a = tab("a");
	const b = tab("b");
	await a.session.start();
	await b.session.start();
	const sending = b.session.perform("gesture", () =>
		Promise.resolve(request(() => {
			journal.set("gesture", "committed");
			return b.first.submitLost();
		}, () => b.first.park<string>()))).then(() => null, (error: unknown) => error);
	await settle();
	a.first.lose();
	await within(new Promise<void>((resolve) => a.session.onRelink(resolve)), "the first tab to relink");
	await settle();
	b.first.lose();
	assertEquals(await within(sending, "the sending tab to settle"), null, "the sending tab confirms its change");
	assertEquals(lookups, ["b:gesture"], "only the tab that holds the receipt looks it up");
	await a.session.close();
	await b.session.close();
});

Deno.test("a prepare that fails after its link was replaced leaves the new link standing", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const { session, dials } = relinking(first.workspace, second.workspace);
	await session.start();
	const parked = Promise.withResolvers<ReturnType<typeof request>>();
	let preparations = 0;
	const sending = session.perform("gesture", () => {
		preparations++;
		if (preparations === 1) return parked.promise;
		return Promise.resolve(
			request(() => Promise.resolve({ status: "committed" }), () => Promise.resolve("committed")),
		);
	}).then(() => null, (error: unknown) => error);
	await settle();
	first.lose();
	await within(new Promise<void>((resolve) => session.onRelink(resolve)), "the page to relink");
	// The first link's prepare answers only now, with that link's closure.
	parked.reject(closed());
	assertEquals(await within(sending, "the send to land over the new link"), null);
	assertEquals([dials(), preparations], [1, 2], "the late failure does not replace the new link");
	await session.close();
});

Deno.test("a change that waited its turn while the link was replaced charges a loss to the new link", async () => {
	const prepared: string[] = [];
	const first = linkedWorkspace("first", [], preparing("first", prepared));
	const second = linkedWorkspace("second", [], preparing("second", prepared));
	let dials = 0;
	const session = viewer(
		first.workspace,
		undefined,
		{
			relink: () => {
				dials++;
				return dials === 1 ? Promise.resolve(second.workspace) : deferred<unknown>().promise;
			},
		},
		false,
		new FakeClock(),
	);
	await session.start();
	// The first change holds the turn until the link has been replaced.
	const holding = deferred<void>();
	const ahead = session.perform("ahead", () => holding.promise.then(() => Promise.reject(closed())));
	const behind = session.perform("behind", async (workspace) => {
		(await workspace().prepareCommand("behind", "1", "say", [])).free();
		throw closed();
	});
	const settled = Promise.allSettled([ahead, behind]);
	await settle();
	first.lose();
	await settle();
	assert(session.link?.live === true && dials === 1, "the new link");
	holding.resolve();
	await settle();
	assert(prepared.length > 0, "the waiting change to be prepared");
	assertEquals(prepared, ["second"], "it is prepared over the link its turn ran on");
	await settle();
	assertEquals(session.link?.live, false, "the loss to end the new link");
	second.lose();
	await session.close();
	await settled;
});
