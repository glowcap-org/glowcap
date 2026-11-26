// A read that sends nothing, and a read after a change that went through, say
// what they are. A read that finds no link in time is not a send that was
// refused, and a follow-up read that fails does not undo a committed change.
import { closed, FakeClock, fakeHandle, linkedWorkspace } from "../support/managed_link.ts";
import { assert, assertEquals } from "../assert.ts";
import { settle } from "../support/wait.ts";
import { viewer } from "../support/managed_viewer.ts";
import { LINK_WAIT_MS } from "../../web/ui/session/managed/link.ts";
import { LocalRefusal } from "../../lib/text/failure.ts";
import { managedSessionText } from "../../lib/text/managed_session.ts";
import { Committed } from "../../web/ui/session/managed/committed.ts";
import { browserFailure, refusalCode } from "../support/browser_failure.ts";

Deno.test("a read that finds no link within the wait says the session could not be read, never that nothing was sent", async () => {
	const first = linkedWorkspace("first", []);
	const clock = new FakeClock();
	const session = viewer(first.workspace, undefined, { relink: () => new Promise(() => {}) }, false, clock);
	await session.start();
	first.lose();
	await settle();
	const reading = session.request((workspace) => workspace.snapshot()).then(() => null, (error: unknown) => error);
	const reached = session.readBeforeSending().then(() => null, (error: unknown) => error);
	clock.advance(LINK_WAIT_MS);
	await settle();
	assertEquals([refusalCode(await reading), refusalCode(await reached)], [
		"local-session-unread",
		"local-session-unread",
	]);
	assert(
		session.linkEnded(await reading),
		"the link ended these reads, so their owners read again over the next link",
	);
	session.link?.close();
});

function after() {
	const reported: { source: string; error: unknown }[] = [];
	const committed = new Committed(fakeHandle<ConstructorParameters<typeof Committed>[0]>({}), (source, error) => {
		reported.push({ source, error });
	});
	return { committed, reported };
}

Deno.test("a follow-up read that fails after a commit is a notice with the read's own refusal, and answers its fallback", async () => {
	const { committed, reported } = after();
	const refused = browserFailure(-12, "Denied", "access-denied");
	assertEquals(await committed.readOr(7, () => Promise.reject(refused)), 7);
	assertEquals(reported.length, 1);
	assertEquals(reported[0].source, managedSessionText.changeUnread);
	assert(reported[0].error === refused, "the notice carries the read's own failure");
});

Deno.test("a follow-up read the link ended, or the session closed under, is left to its owner", async () => {
	const { committed, reported } = after();
	const lost = closed();
	assertEquals(await committed.readOr(0, () => Promise.reject(lost)).then(() => null, (e: unknown) => e), lost);
	const own = new LocalRefusal("session-closed");
	assertEquals(await committed.readOr(0, () => Promise.reject(own)).then(() => null, (e: unknown) => e), own);
	assertEquals(await committed.readOr(0, () => Promise.resolve(7)), 7);
	assertEquals(reported.length, 0);
});
