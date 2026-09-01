// IRC identity and presence projections in the Rooms UI store.

/// <reference lib="dom" />

import type { RoomConv } from "../../web/ui/types.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({
		matches: false,
		addEventListener() {},
		removeEventListener() {},
	}),
});

const store = await import("../../web/ui/store.ts");
const projection = new store.PageProjection();
const { dirId } = await import("../../web/ui/types.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

/** One seat fact, as a bridge would put it on the wire.
 *
 * The badge and sentence are a bridge's own words and this file is about what
 * the store does with a seat, not about what any bridge calls one, so they are
 * placeholders here. `member_identity_test.ts` proves they are carried through
 * and `test/irc/bridge_test.ts` pins what IRC actually writes. */
function seat(
	name: string,
	state: "rooms" | "connecting" | "linked" | "failed",
	nick: string,
	network = "Libera",
) {
	return { kind: "seat", name, state, nick, network, badge: "SEAT", said: `seat ${state}` } as const;
}

Deno.test("an IRC seat annotates one Rooms member and never mints another", () => {
	const room = store.ensureRoom(projection, dirId("irc-seat-state"), "bridge");
	store.applyPresence(projection, room.key, { kind: "roster", names: ["alice", "irc/bo"] });
	store.applyPresence(projection, room.key, seat("alice", "connecting", "alice_irc"));
	let conv = store.getConv(projection, room.key);
	assert(conv?.type === "room", "the bridged room disappeared");
	let roster = store.membersOf(projection, room.key);
	assert(roster.size === 2, "a seat projection minted another roster member");
	assert(roster.get("alice")?.seat?.state === "connecting", "the connecting seat was not shown");
	store.applyPresence(projection, room.key, seat("alice", "linked", "alice_irc"));
	conv = store.getConv(projection, room.key);
	roster = store.membersOf(projection, room.key);
	assert(conv?.type === "room" && roster.get("alice")?.seat?.state === "linked", "the seat never linked");
	assert(roster.get("alice")?.seat?.nick === "alice_irc", "the linked IRC nick was lost");
	store.applyPresence(projection, room.key, seat("nobody", "linked", "intruder"));
	conv = store.getConv(projection, room.key);
	roster = store.membersOf(projection, room.key);
	assert(conv?.type === "room" && !roster.has("nobody"), "a seat fact invented a Rooms member");
	store.applyPresence(projection, room.key, seat("alice", "rooms", "alice_irc"));
	conv = store.getConv(projection, room.key);
	roster = store.membersOf(projection, room.key);
	assert(
		conv?.type === "room" && roster.get("alice")?.seat?.state === "rooms",
		"a Rooms-only transition was lost",
	);
	store.applyPresence(projection, room.key, { kind: "roster", names: ["alice", "irc/bo"] });
	conv = store.getConv(projection, room.key);
	roster = store.membersOf(projection, room.key);
	assert(
		conv?.type === "room" && roster.get("alice")?.seat === undefined,
		"a full roster kept a stale seat projection",
	);
});

Deno.test("IRC identity intent follows its network across bridged rooms", () => {
	const directory = dirId("irc-network-intent");
	const one = store.ensureRoom(projection, directory, "Libera/#one");
	const two = store.ensureRoom(projection, directory, "Libera/#two");
	for (const room of [one, two]) {
		// Each channel states the bridge behind it, and the scope is the network.
		// That is what makes a sibling reachable by an answer given elsewhere: it
		// is on this network whether or not anybody has linked on it yet.
		store.setBridgeFacts(projection, room.key, {
			prefix: "irc/",
			badge: "IRC",
			said: "IRC only",
			scope: "Libera",
		});
		store.applyPresence(projection, room.key, { kind: "roster", names: ["alice"] });
		store.applyPresence(projection, room.key, seat("alice", "linked", "alice_irc"));
	}
	const identity = {
		scope: "Libera",
		action: "link",
		answers: { nick: "registered" },
		secretsGiven: false,
	} as const;
	store.setRoomBridgeIntent(projection, one.key, identity, "Libera");
	assert(
		(store.getConv(projection, one.key) as RoomConv).bridgeIntent?.answers["nick"] === "registered",
		"the chosen room lost its IRC intent",
	);
	assert(
		(store.getConv(projection, two.key) as RoomConv).bridgeIntent?.answers["nick"] === "registered",
		"the sibling channel kept another identity",
	);
	store.clearRoomBridgeIntent(projection, two.key);
	assert(
		(store.getConv(projection, one.key) as RoomConv).bridgeIntent === null,
		"network disconnect left the first channel linked",
	);
	assert(
		(store.getConv(projection, two.key) as RoomConv).bridgeIntent === null,
		"network disconnect left the second channel linked",
	);
});
