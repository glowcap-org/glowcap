// A new build reloads the page only when the reload loses nothing a person
// made. An edit staged or being written, and a change still being prepared,
// would be lost. A write or a change the session holds a receipt of is
// adopted again by the reloaded page, so neither holds the reload back.
import { assertEquals } from "../assert.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { request, timedOutOutcome } from "../support/managed_link.ts";
import { settle } from "../support/wait.ts";

function withDraft() {
	const accepted = snapshot();
	accepted.intent.conversations.push({
		kind: "direct",
		id: "dm",
		directory: "dir",
		peer: "peer",
		access: null,
		closed: false,
		draft: "old",
	});
	return accepted;
}

/** The session took a write of `draft`, which its snapshot now holds. */
function written(accepted: ReturnType<typeof snapshot>, draft: string) {
	const row = accepted.intent.conversations.find((conversation) => conversation.id === "dm");
	if (row != null) row.draft = draft;
}

Deno.test("an edit holds a reload back until the session holds a write of its text", async () => {
	const accepted = withDraft();
	let submissions = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(accepted),
		prepareCommand: (_operation: string, _revision: string, _name: string, args: string[]) =>
			Promise.resolve({
				// The first write reaches the session but its answer is lost.
				submit: () => {
					written(accepted, args[1]);
					return ++submissions === 1
						? Promise.resolve(timedOutOutcome())
						: Promise.resolve({ status: "committed" });
				},
				status: () => Promise.resolve("committed"),
				result: () => Promise.resolve(null),
				free() {},
			}),
	});
	await session.readNow();
	assertEquals(session.reloadLoses, false, "a page with nothing staged reloads");
	session.drafts.stage("dm", "first");
	assertEquals(session.reloadLoses, true, "a staged edit would be lost");
	await Promise.allSettled([session.drafts.flush("dm")]);
	assertEquals(session.pending.length, 1, "the session holds the write");
	assertEquals(session.reloadLoses, false, "the reloaded page adopts the held write");
	session.drafts.stage("dm", "latest");
	assertEquals(session.reloadLoses, true, "no held write carries the newer text");
	await session.drafts.flush("dm");
	assertEquals(session.reloadLoses, false);
	await session.close();
});

Deno.test("a change holds a reload back only while it is prepared", async () => {
	const session = viewer({ snapshot: () => Promise.resolve(snapshot()) });
	await session.readNow();
	const prepared = deferred<ReturnType<typeof request>>();
	const answer = deferred<string>();
	const sending = session.perform("gesture", () => prepared.promise).then(() => null, (error: unknown) => error);
	await settle();
	assertEquals(session.reloadLoses, true, "a change being prepared would be lost");
	prepared.resolve(request(() => Promise.resolve({ status: "pending" }), () => answer.promise));
	await settle();
	assertEquals(session.pending, ["gesture"], "the session holds the change");
	assertEquals(session.reloadLoses, false, "the reloaded page adopts the held change");
	answer.resolve("committed");
	await sending;
	await session.close();
});

Deno.test("a held write the session has not confirmed holds a reload back", async () => {
	const session = viewer({
		snapshot: () => Promise.resolve(withDraft()),
		prepareCommand: () =>
			Promise.resolve({
				// The answer is lost and the session never says the write landed.
				submit: () => Promise.resolve(timedOutOutcome()),
				status: () => Promise.resolve("pending"),
				result: () => Promise.resolve(null),
				free() {},
			}),
	});
	await session.readNow();
	session.drafts.stage("dm", "first");
	await Promise.allSettled([session.drafts.flush("dm")]);
	assertEquals(session.pending.length, 1, "the session holds the write");
	assertEquals(session.reloadLoses, true, "the reloaded page could not say the text landed");
	await session.close();
});
