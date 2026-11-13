// A verb that answers with one capability is refused when it answers anything else, and what the
// wrong answer carried is released, whether it arrives in time or after the deadline.
import type { Argument, Ref, Session } from "@glowcap/runtime";
import { refFromId } from "../../../bindings/ts/runtime/value.ts";
import { RoomInvitation } from "../lib/room/invitation.ts";
import { askRef } from "../lib/ask.ts";
import { errorMessage } from "../lib/error_message.ts";
import { Directory } from "../lib/directory.ts";
import { DirectoryPeering, type DurableRoom } from "../lib/peering.ts";
import { REQUEST_TIMEOUT_MS } from "../lib/limits.ts";
import { assert, assertEquals } from "./assert.ts";

function peer(answer: Argument): { session: Session; released: Ref[] } {
	const released: Ref[] = [];
	const session = {
		send: () => Promise.resolve(answer),
		release: (ref: Ref) => released.push(ref),
	} as unknown as Session;
	return { session, released };
}

async function refusal(work: () => Promise<unknown>): Promise<string> {
	try {
		await work();
	} catch (error) {
		return errorMessage(error);
	}
	return "";
}

Deno.test("an invitation claim answered with a list holding a reference releases that reference", async () => {
	const stray = refFromId(7n);
	const { session, released } = peer([stray]);
	const said = await refusal(() => new RoomInvitation(session, refFromId(1n)).claim());
	assertEquals(said, "the room invitation answered without an entrance capability");
	assert(released.length === 1 && released[0] === stray, "the reference in the wrong answer was not released");
});

Deno.test("askRef answers the reference, and refuses in the caller's sentence", async () => {
	const answered = refFromId(3n);
	assert(
		await askRef(peer(answered).session, refFromId(1n), "verb", [], "no answer", "wrong answer") === answered,
		"a reference answer was not returned as it came",
	);
	const stray = refFromId(9n);
	const { session, released } = peer(["text", [stray]]);
	assertEquals(
		await refusal(() => askRef(session, refFromId(1n), "verb", [], "no answer", "wrong answer")),
		"wrong answer",
	);
	assert(released.length === 1 && released[0] === stray, "the reference in the wrong answer was not released");
});

Deno.test("a lease answered as a list holding a reference releases that reference", async () => {
	const authority = refFromId(10n);
	const durable = refFromId(11n);
	const stray = refFromId(12n);
	const released: Ref[] = [];
	const destination = {
		fetch: () => Promise.resolve(authority),
		send: () => Promise.resolve([stray]),
		release: (ref: Ref) => released.push(ref),
	} as unknown as Session;
	const source = {
		session: {
			profile: { captpVersion: "v1_0", codec: "syrup", features: 0 },
			host: { enliven: () => Promise.resolve(durable) },
			release() {},
		},
	} as unknown as Directory;
	const room: DurableRoom = { reference: durable, link: () => Promise.resolve("ocapn://source.example/s/room") };
	const peering = await DirectoryPeering.fetch({ session: destination } as Directory, "swiss");
	const said = await refusal(() => peering.publish("late", room, source));
	assertEquals(said, "publishDurableRoom did not return a lease capability");
	assert(released.includes(stray), "the reference in the wrong lease answer was not released");
});

Deno.test("an introduction answered as a list holding a reference releases that reference", async () => {
	const inbox = refFromId(20n);
	const stray = refFromId(21n);
	const released: Ref[] = [];
	const session = {
		serve: () => Promise.resolve(),
		fetch: () => Promise.resolve(inbox),
		sendRedeeming: () => Promise.resolve({ reply: [stray], via: null }),
		release: (ref: Ref) => released.push(ref),
		close: () => Promise.resolve(),
	} as unknown as Session;
	const directory = await Directory.connect("ocapn://fixture.tcp", () => Promise.resolve(session));
	const said = await refusal(() => directory.introduceVia("bob", "11111111-1111-4111-8111-111111111111"));
	assertEquals(said, 'introduce("bob") did not return a capability');
	assert(released.includes(stray), "the reference in the wrong introduction answer was not released");
});

Deno.test("a reference that answers after the deadline is released once", async () => {
	const late = refFromId(30n);
	const released: Ref[] = [];
	const answer = Promise.withResolvers<Argument>();
	const session = {
		send: () => answer.promise,
		release: (ref: Ref) => released.push(ref),
	} as unknown as Session;
	const realSetTimeout = globalThis.setTimeout;
	globalThis.setTimeout =
		((run: () => void, ms?: number, ...rest: unknown[]) =>
			realSetTimeout(run, ms === REQUEST_TIMEOUT_MS ? 0 : ms, ...rest)) as typeof setTimeout;
	let said = "";
	try {
		said = await refusal(() => askRef(session, refFromId(1n), "verb", [], "nobody answered", "wrong"));
	} finally {
		globalThis.setTimeout = realSetTimeout;
	}
	assertEquals(said, "nobody answered");
	answer.resolve(late);
	await new Promise((resolve) => realSetTimeout(resolve, 0));
	assert(released.length === 1 && released[0] === late, "the late reference was not released exactly once");
});
