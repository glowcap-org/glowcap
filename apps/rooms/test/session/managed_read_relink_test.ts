// What a read of the session does while the link is being replaced. A press
// that has sent nothing waits for the new link and reads there, or ends with
// the link's refusal. A read for work under way fails at once, so a follow-up
// to a sent change never waits and then ends as if nothing was sent.
import { assert, assertEquals } from "../assert.ts";
import { settle } from "../support/wait.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { closed, FakeClock, linkedWorkspace } from "../support/managed_link.ts";
import { browserFailure } from "../support/browser_failure.ts";

/** A first link whose snapshot fails once it is lost, as a read over a closed
 * connection does, and holds the directory a public room names. */
function losing() {
	let lost = false;
	const accepted = snapshot();
	accepted.intent.directories.push({
		id: "d",
		access: "access",
		home: false,
		nick: "n",
		nickAllocation: "exact",
		standing: null,
	});
	const first = linkedWorkspace("first", [], {
		snapshot: () => lost ? Promise.reject(closed()) : Promise.resolve(structuredClone(accepted)),
	});
	return {
		first,
		accepted,
		lose() {
			lost = true;
			first.lose();
		},
	};
}

Deno.test("a press whose first step reads the session waits for the new link and reads there", async () => {
	const { first, accepted, lose } = losing();
	const dial = deferred<unknown>();
	const prepared = new Error("prepared over the new link");
	let reads = 0;
	const second = linkedWorkspace("second", [], {
		snapshot: () => {
			reads++;
			return Promise.resolve(structuredClone(accepted));
		},
		preparePublicRoom: () => Promise.reject(prepared),
	});
	const session = viewer(first.workspace, undefined, { relink: () => dial.promise }, false, new FakeClock());
	await session.start();
	lose();
	await settle();
	assert(session.link?.state.kind === "dialing", "the page to dial again");
	let outcome: unknown = "pending";
	const press = session.actions.publicRoom("d", "room", "publication").then(
		() => null,
		(error: unknown) => error,
	).then((settled) => outcome = settled);
	await settle();
	assertEquals(outcome, "pending", "the press waits for the link");
	dial.resolve(second.workspace);
	await press;
	assertEquals(outcome, prepared, "read and prepared over the new link");
	assert(reads > 0, "the press read the new link");
	second.lose();
	await session.close();
});

Deno.test("a press whose first step reads the session ends with the link's refusal when the dial is refused", async () => {
	const { first, lose } = losing();
	const revoked = browserFailure(-12, "The saved access was revoked", "session-restoration-failed");
	const refused = { relink: () => Promise.reject(revoked) };
	const session = viewer(first.workspace, undefined, refused, false, new FakeClock());
	await session.start();
	lose();
	await settle();
	assert(session.link?.state.kind === "refused", "the refusal");
	const met = await session.actions.publicRoom("d", "room", "publication").then(() => null, (error) => error);
	assertEquals(met, revoked, "the press says why the link ended, not that the session is unreachable");
	await session.close();
});

Deno.test("a read for work under way fails at once while the link is being replaced", async () => {
	const { first, lose } = losing();
	const dial = deferred<unknown>();
	const session = viewer(first.workspace, undefined, { relink: () => dial.promise }, false, new FakeClock());
	await session.start();
	lose();
	await settle();
	assert(session.link?.state.kind === "dialing", "the page to dial again");
	let outcome: unknown = "pending";
	const read = session.readNow().then(() => null, (error: unknown) => error).then((settled) => outcome = settled);
	await settle();
	assert(outcome instanceof Error, "the read ends before the new link comes");
	dial.resolve(linkedWorkspace("second", []).workspace);
	await read;
	await session.close();
});
