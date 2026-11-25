// A saved management control is restored the same way when the page opens
// and when its link is replaced. One whose session does not answer keeps a
// row that says why, which Try now or the next link reaches, and which the
// person can remove. A restore and a move run one at a time, so a control
// restored while the link moves is moved too.
import { assert, assertEquals } from "../assert.ts";
import { connectionLost } from "../../lib/text/failure.ts";
import {
	bindingHandle,
	closed,
	everyReached,
	FakeClock,
	linkedWorkspace,
	savedHandle,
} from "../support/managed_link.ts";
import { browserFailure, refusalCode } from "../support/browser_failure.ts";
import { deferred, viewer } from "../support/managed_viewer.ts";
import { settle, until, within } from "../support/wait.ts";
import { handleOf } from "../../web/ui/session/managed/held_control.ts";
import { rowOffers } from "../../web/ui/session/managed/access_row.ts";
import { unreachedAccess } from "../../lib/text/managed_access.ts";
import type { AccessMove } from "../../web/ui/session/managed/control_reach.ts";

/** A restore at page open that keeps each failure it is told. */
function told(failures: unknown[]): AccessMove {
	return { current: () => true, report: (_id, error) => failures.push(error), probe() {} };
}

/** A local page whose saved controls answer, in order, as `answers` says. */
function restoring(answers: (() => Promise<unknown>)[], workspace: Record<string, unknown> = {}) {
	const asked: string[] = [];
	const session = viewer(workspace, () => {}, {
		savedControl: (id: string) => {
			asked.push(id);
			return answers.shift()?.() ?? Promise.reject(new Error("restored once too often"));
		},
	});
	return { session, asked };
}

Deno.test("a saved access whose session does not answer when the page opens keeps a row, and Try now reaches it", async () => {
	const freed: string[] = [];
	const { session } = restoring([() => Promise.reject(closed()), () => Promise.resolve(savedHandle(freed, "later"))]);
	const failures: unknown[] = [];
	await session.management.restore(["down"], told(failures));
	const [row] = session.management.held;
	assert(row != null, "the access keeps a row");
	assert(row.state.kind === "undescribed" && connectionLost(row.state.failure), "the row says why");
	assertEquals(failures.length, 1, "the failure is reported once");
	await within(session.management.reachAgain(row), "the access to be reached");
	assertEquals(row.state.kind, "reached");
	assertEquals(Reflect.get(handleOf(row) ?? {}, "name"), "later");
	await session.close();
	assertEquals(freed, ["later"]);
});

Deno.test("a saved access whose dial never got its turn says so on its row, and Try now reaches it", async () => {
	const freed: string[] = [];
	// As the browser binding rejects a saved dial whose wait for this browser's
	// storage outlasts its bound: a coded failure with no binding status.
	const unasked = browserFailure(
		null,
		"Saved management dial waited too long for its turn",
		"session-not-reached-yet",
	);
	const { session } = restoring([() => Promise.reject(unasked), () => Promise.resolve(savedHandle(freed, "later"))]);
	await session.management.restore(["waited"], told([]));
	const [row] = session.management.held;
	assert(row != null, "the access keeps a row");
	const offers = rowOffers(session.management, row);
	const summary = unreachedAccess.get("session-not-reached-yet")?.summary ?? "";
	assert(summary !== "", "the row's words are known");
	assertEquals(
		[row.state.kind, connectionLost(unasked), offers.tryNow, offers.failure?.startsWith(summary)],
		["undescribed", false, true, true],
		"the row says its session was never asked, and offers Try now",
	);
	await within(session.management.reachAgain(row), "the access to be reached");
	assertEquals(row.state.kind, "reached");
	await session.close();
	assertEquals(freed, ["later"]);
});

Deno.test("a saved access never reached can be removed, which releases its row", async () => {
	let released = 0;
	const { session } = restoring([() => Promise.reject(closed())], {
		prepareForgetControl: () => {
			released++;
			return Promise.resolve(null);
		},
	});
	await session.management.restore(["down"], told([]));
	const [row] = session.management.held;
	assert(row != null, "the access keeps a row");
	await within(session.management.forget(row), "the row to be removed");
	assertEquals([released, session.management.held.length], [1, 0]);
	await session.close();
});

Deno.test("a removed access holds no handle, so neither a card open from before nor the next link reaches a freed one", async () => {
	const reports: unknown[] = [];
	let restores = 0;
	let released = 0;
	const first = linkedWorkspace("first", [], {
		prepareForgetControl: () => {
			released++;
			return Promise.resolve(null);
		},
	});
	const second = linkedWorkspace("second", []);
	const session = viewer(
		first.workspace,
		(_source, error) => reports.push(error),
		{
			savedControl: () => {
				restores++;
				return Promise.resolve(bindingHandle({
					describe: () => Promise.resolve({ available: true, revision: "1" }),
					prepareLabel: () => Promise.resolve({ free() {} }),
					free() {},
				}));
			},
			relink: () => Promise.resolve(second.workspace),
		},
		false,
		new FakeClock(),
	);
	await session.start();
	await session.management.restore(["saved"], told(reports));
	const [card] = session.management.held;
	assert(card != null, "the access is held");
	await session.management.forget(card);
	first.lose();
	await until(() => session.link?.live === true, "the new link");
	await settle();
	const pressed = await Promise.all(
		[
			session.management.prepare(card, { kind: "label", label: "renamed" }, "1"),
			session.management.reachAgain(card),
			session.management.forget(card),
		].map((press) => press.then(() => null, (error: unknown) => refusalCode(error))),
	);
	assertEquals(pressed, ["local-not-sent", null, null], "each press on the removed access sends nothing");
	assertEquals([restores, released, session.management.held.length, reports], [1, 1, 0, []]);
	// Removing it again from that card leaves the access held anew under its id.
	await session.management.restore(["saved"], told(reports));
	const [again] = session.management.held;
	await session.management.forget(card);
	assertEquals([released, session.management.held, reports], [1, [again], []]);
	await session.close();
});

Deno.test("the next link reaches a saved access the page could not reach when it opened", async () => {
	const freed: string[] = [];
	const answers = [() => Promise.reject(closed()), () => Promise.resolve(savedHandle(freed, "over the new link"))];
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const session = viewer(
		first.workspace,
		() => {},
		{
			savedControl: () => answers.shift()?.() ?? Promise.reject(new Error("restored once too often")),
			relink: () => Promise.resolve(second.workspace),
		},
		false,
		new FakeClock(),
	);
	await session.start();
	await session.management.restore(["down"], told([]));
	first.lose();
	const [row] = session.management.held;
	await until(() => row.state.kind === "reached", "the access to be reached over the new link");
	assertEquals(Reflect.get(handleOf(row) ?? {}, "name"), "over the new link");
	await session.close();
});

Deno.test("an access restored while the link moves is moved too, so no row keeps the replaced link", async () => {
	const freed: string[] = [];
	const opening = deferred<unknown>();
	const answers = [() => opening.promise, () => Promise.resolve(savedHandle(freed, "new"))];
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const session = viewer(
		first.workspace,
		() => {},
		{
			savedControl: () => answers.shift()?.() ?? Promise.reject(new Error("restored once too often")),
			relink: () => Promise.resolve(second.workspace),
		},
		false,
		new FakeClock(),
	);
	await session.start();
	let moved = false;
	session.onRelink(() => moved = true);
	const restored = session.management.restore(["saved"], everyReached);
	first.lose();
	await until(() => session.link?.live === true, "the new link");
	await settle();
	assertEquals(
		[moved, answers.length],
		[true, 1],
		"the page moves while held access waits for the restore under way",
	);
	// The restore over the replaced link lands while the access move waits for it.
	opening.resolve(savedHandle(freed, "old"));
	await within(restored, "the restore");
	await until(() => freed.includes("old"), "the move to reach the access again");
	const [row] = session.management.held;
	assertEquals(Reflect.get(handleOf(row) ?? {}, "name"), "new");
	await session.close();
});

Deno.test("two Try nows on an access never reached take turns, so the second finds it reached and asks nothing", async () => {
	const freed: string[] = [];
	const { session } = restoring([
		() => Promise.reject(closed()),
		() => Promise.resolve(savedHandle(freed, "first")),
		() => Promise.resolve(savedHandle(freed, "second")),
	]);
	await session.management.restore(["down"], told([]));
	const [row] = session.management.held;
	assert(row != null && row.state.kind === "undescribed", "the access keeps a row it never reached");
	await within(
		Promise.all([session.management.reachAgain(row), session.management.reachAgain(row)]),
		"both reaches to land",
	);
	assertEquals([Reflect.get(handleOf(row) ?? {}, "name"), freed], ["first", []]);
	await session.close();
	assertEquals(freed, ["first"], "the second Try now made no handle, and close frees the one held");
});

Deno.test("a read of an access removed while it was under way ends with nothing", async () => {
	const description = deferred<unknown>();
	let reads = 0;
	const { session } = restoring([() =>
		Promise.resolve(bindingHandle({
			describe: () => ++reads === 1 ? Promise.resolve({ available: true, revision: "1" }) : description.promise,
			free() {},
		}))], { prepareForgetControl: () => Promise.resolve(null) });
	await session.management.restore(["saved"], everyReached);
	const [row] = session.management.held;
	assert(row != null, "the access is held");
	const reading = session.management.refresh(row).then(() => null, (error: unknown) => error);
	await settle();
	await session.management.forget(row);
	description.resolve({ available: true, revision: "2" });
	assertEquals([await reading, session.management.held], [null, []]);
	await session.close();
});
