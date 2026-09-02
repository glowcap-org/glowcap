import { type Argument, type Behavior, Ref, type Session } from "@glowcap/runtime";
import { ROOMS_SESSION_ARCHIVE_SHARE_READ, ROOMS_SESSION_EVENT, RoomsSessionClient } from "../../lib/session/client.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { assertEquals } from "../assert.ts";

function ref(): Ref {
	return Object.create(Ref.prototype) as Ref;
}

function snapshot(): Argument {
	return [
		0n,
		JSON.stringify(emptyRoomsSessionState()),
		[],
		[],
		[],
		[],
		null,
		"[]",
		"[]",
		"[]",
		JSON.stringify({ version: 1, rights: "admin", workspaceAdoption: "closed", grants: [] }),
		"[]",
	];
}

function line(blob: Ref): Argument[] {
	return [
		"lines",
		1n,
		"room",
		"bo",
		"file",
		1n,
		1n,
		"said",
		false,
		null,
		null,
		null,
		false,
		null,
		null,
		"file",
		"note.txt",
		"text/plain",
		1n,
		blob,
		0n,
		0n,
	];
}

Deno.test("a Rooms session watcher releases unobserved and malformed line capabilities", async () => {
	let observerBehavior: Behavior | null = null;
	const observer = ref();
	const released: Ref[] = [];
	const session = {
		spawn(behavior: Behavior) {
			observerBehavior = behavior;
			return observer;
		},
		send: () => Promise.resolve(snapshot()),
		release: (capability: Ref) => released.push(capability),
	} as unknown as Session;
	const client = new RoomsSessionClient(session, ref());
	await client.watch(() => {});
	assertEquals(released, [observer]);

	const unobserved = ref();
	observerBehavior!(ROOMS_SESSION_EVENT, line(unobserved));
	assertEquals(released, [observer, unobserved]);

	const malformed = ref();
	const invalid = line(malformed);
	invalid[0] = "";
	let refused = false;
	try {
		observerBehavior!(ROOMS_SESSION_EVENT, invalid);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released, [observer, unobserved, malformed]);

	const unexpected = ref();
	refused = false;
	try {
		observerBehavior!("unknown", [unexpected]);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released, [observer, unobserved, malformed, unexpected]);
});

Deno.test("archive-share pagination cannot change the share being read", async () => {
	let page = 0;
	const session = {
		send: (_target: Ref, verb: string) => {
			if (verb !== ROOMS_SESSION_ARCHIVE_SHARE_READ) throw new Error(`unexpected ${verb}`);
			page += 1;
			const view = {
				id: "share",
				directory: "directory",
				conversationId: page === 1 ? "first" : "second",
				from: "peer",
				status: "reading",
				error: "",
				kind: "direct",
				scopeConversation: "first",
				custody: "live",
				sturdyref: "",
			};
			return Promise.resolve([JSON.stringify(view), 1n, page === 1, []] as Argument);
		},
	} as unknown as Session;
	let refused = "";
	try {
		await new RoomsSessionClient(session, ref()).readArchiveShare("share");
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	}
	assertEquals(refused.includes("between pages"), true);
});
