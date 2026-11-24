// An opening that is dismissed after its change committed leaves what it
// joined. A link lost before the departure goes out is not the end of that:
// the same departure goes out over the link that replaces it, once.
import { closed, fakeEnvironment, fakeHandle, ownerEntry } from "../support/managed_link.ts";
import { snapshot } from "../support/managed_viewer.ts";
import { assert, assertEquals } from "../assert.ts";
import { managedSessionText } from "../../lib/text/managed_session.ts";
import { settle } from "../support/wait.ts";
import { connectionLost, LocalRefusal } from "../../lib/text/failure.ts";
import { ConversationOpening, LEAVE_ATTEMPTS, LEAVE_BACKOFF_MS } from "../../web/ui/session/managed/openings.ts";
import type { ManagedLink } from "../../web/ui/session/managed/link.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { ManagedOperation } from "../../web/ui/session/managed/operation.ts";

function joined() {
	const read = snapshot();
	read.intent.conversations.push({
		kind: "room",
		id: "room",
		directory: "directory",
		name: "garden",
		access: "entry",
		control: null,
		reconnect: "requested",
		standing: null,
		draft: "",
	});
	return read;
}

function leaving(answers: Array<"lost" | "refused" | "denied" | "sent">, relinks: Array<boolean>) {
	const sent: string[] = [];
	const done: string[] = [];
	const waits: boolean[] = [];
	const refused = new LocalRefusal("not-sent");
	const denied = new Error("denied");
	const link = fakeHandle<ManagedLink>({
		available: () => {
			const live = relinks.shift() ?? false;
			waits.push(live);
			return Promise.resolve(live);
		},
	});
	const { clock, notices, effects } = fakeEnvironment();
	const session = fakeHandle<ManagedRoomsSession>({
		pending: [],
		link,
		effects,
		readBeforeSending: () => Promise.resolve(joined()),
		linkEnded: (error: unknown) => connectionLost(error) || error === refused,
		...ownerEntry({
			command: (_name: string, _args: string[], operation?: string) => {
				sent.push(operation ?? "");
				const answer = answers.shift() ?? "sent";
				if (answer === "lost") return Promise.reject(closed());
				if (answer === "refused") return Promise.reject(refused);
				if (answer === "denied") return Promise.reject(denied);
				return Promise.resolve(fakeHandle<ManagedOperation>({ id: operation ?? "" }));
			},
			completeResult: (command: ManagedOperation) => {
				done.push(command.id);
				return Promise.resolve();
			},
		}),
	});
	return { session, sent, done, waits, refused, denied, clock, notices };
}

Deno.test("a departure lost with its link goes out again, as the same operation, over the next link", async () => {
	const { session, sent, done } = leaving(["lost", "sent"], [true]);
	const opening = new ConversationOpening(session);
	await opening.acquired("room");
	opening.abort();
	await opening.drain();
	assertEquals(sent.length, 2, "the departure went out again");
	assertEquals(sent[0], sent[1], "as the one operation, so nothing departs twice");
	assertEquals(done, [sent[0]]);
});

Deno.test("a departure held back by a link that never comes is tried a bounded number of times, then ends with the link's own refusal and a notice", async () => {
	const { session, sent, refused, clock, notices } = leaving(Array(LEAVE_ATTEMPTS).fill("refused"), []);
	const opening = new ConversationOpening(session);
	await opening.acquired("room");
	opening.abort();
	const draining = opening.drain().then(() => null, (error: unknown) => error);
	for (let attempt = 1; attempt < LEAVE_ATTEMPTS; attempt++) {
		await settle();
		assertEquals(sent.length, attempt, "each wait is over before the next try");
		clock.advance(LEAVE_BACKOFF_MS * 2 ** (attempt - 1));
	}
	assertEquals(await draining, refused, "the person is told by the refusal and the link's notice");
	assertEquals(sent.length, LEAVE_ATTEMPTS, "the tries stop at the bound");
	assertEquals(new Set(sent).size, 1, "every try is the one operation, so nothing departs twice");
	assertEquals(notices.map((notice) => notice.source), [managedSessionText.leaveUnfinished]);
	assert(notices[0].error === refused, "the notice carries the refusal");
});

Deno.test("a departure refused for a reason that does not clear with time ends at once with a notice", async () => {
	const { session, sent, denied, notices } = leaving(["denied"], []);
	const opening = new ConversationOpening(session);
	await opening.acquired("room");
	opening.abort();
	assertEquals(await opening.drain().then(() => null, (error: unknown) => error), denied);
	assertEquals(sent.length, 1, "one try, no wait");
	assertEquals(notices.map((notice) => notice.source), [managedSessionText.leaveUnfinished]);
});
