// Moves run one at a time, so the move to a link can run after the person has
// started work over that link. Such a move ends only what the replaced link
// held, and work held from a replaced link is never sent over a new one.
import { assertEquals } from "../assert.ts";
import { settle, until, within } from "../support/wait.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { backedOff, closed, FakeClock, linkedWorkspace } from "../support/managed_link.ts";
import { refusalCode } from "../support/browser_failure.ts";

/** A page whose startup adoption the first link's loss cut short, so the move
 * to the second link goes on with it there and waits until `gate` opens. The
 * move to the third link then runs only after work has begun over it. Each
 * link prepares a workspace acquisition whose submission goes unanswered, and
 * counts what it submits in `sent`. */
async function slowMove() {
	const sent = { second: 0, third: 0 };
	const preparing = (name: "second" | "third") => ({
		prepareAcquisition: () =>
			Promise.resolve({
				submit: () => {
					sent[name]++;
					return Promise.resolve({ status: "uncertain", reason: "the reply never came" });
				},
				reprepare: () => Promise.reject(closed()),
				free() {},
			}),
	});
	const first = linkedWorkspace("first", [], { effects: () => first.park() });
	const gate = deferred<void>();
	let adopting = 0;
	const second = linkedWorkspace("second", [], {
		...preparing("second"),
		effects: () => {
			adopting++;
			return gate.promise.then(() => []);
		},
	});
	const third = linkedWorkspace("third", [], preparing("third"));
	const links = [second, third];
	const reported: unknown[] = [];
	const clock = new FakeClock();
	const session = viewer(
		first.workspace,
		(_source, error) => reported.push(error),
		{
			relink: () => {
				const next = links.shift();
				return next == null
					? Promise.reject(new Error("two new links at most"))
					: Promise.resolve(next.workspace);
			},
		},
		false,
		clock,
	);
	let moved = 0;
	session.onRelink(() => moved++);
	const opened = session.start();
	await settle();
	first.lose();
	await within(opened, "the page to open");
	await until(() => session.link?.live === true && adopting === 1, "the move to the second link to wait");
	/** Start a workspace change, which the session leaves unanswered and the page holds. */
	const held = async () => refusalCode(await session.actions.replace(snapshot()).then(() => null, (error) => error));
	/** Replace the second link with the third. */
	const replace = async () => {
		second.lose();
		await backedOff(session, clock);
		await until(() => session.link?.live === true && links.length === 0, "the third link");
	};
	return { session, gate, sent, reported, held, replace, moved: () => moved };
}

Deno.test("a move that runs after work began over its own link leaves that work held", async () => {
	const f = await slowMove();
	await f.replace();
	assertEquals(await f.held(), "local-acquisition-unknown");
	f.gate.resolve();
	await until(() => f.moved() === 2, "the move to the third link");
	await settle();
	assertEquals(f.reported, [], "nothing prepared over the newest link is ended");
	assertEquals(f.session.actions.pending.length, 1);
	await f.session.close();
});

Deno.test("work held from a replaced link, tried again before the move ends it, ends unsent over the new link", async () => {
	const f = await slowMove();
	assertEquals(await f.held(), "local-acquisition-unknown");
	await f.replace();
	const [id] = f.session.actions.pending;
	const retried = await f.session.actions.recoverAcquisition(id).then(() => null, (error: unknown) => error);
	assertEquals(refusalCode(retried), "local-receipt-lost");
	assertEquals(f.sent, { second: 1, third: 0 });
	f.gate.resolve();
	await f.session.close();
});
