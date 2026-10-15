// IRC store projection carries bridge facets, seat progress, and network-scoped identity into room state.
/// <reference lib="dom" />
import "../support/browser_application.ts";
// IRC identity and presence projections in the Rooms UI store.

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

// Unknown-seat admission and roster reset are exercised by the host/Wasm
// contract in rust/proofs/src/room_view.rs. This seam receives complete views.
function view(state?: "rooms" | "connecting" | "linked" | "failed"): import("../../web/ui/store.ts").RoomViewUpdate {
	return {
		members: [
			["alice", {
				online: true,
				away: "",
				...(state == null ? {} : {
					seat: {
						state,
						nick: "alice_irc",
						network: "Libera",
						badge: "SEAT",
						said: `seat ${state}`,
					},
				}),
			}],
			["irc/bo", { online: true, away: "" }],
		],
		topic: null,
		lineBytes: null,
		// IRC holds no bytes, keeps no previews, and relays no typing: the
		// facet is withheld and the statement names nothing.
		carries: { previews: false, typing: false },
		canSetTopic: false,
		canPostFiles: false,
		canModerate: false,
		bridge: { prefix: "irc/", badge: "IRC", said: "IRC only", scope: "Libera" },
	};
}

Deno.test("a bridged room withholds files and states what it carries, and the page draws from both", () => {
	const room = store.ensureRoom(projection, dirId("irc-carries"), "bridge");
	store.setRoomView(projection, room.key, view());
	const bridged = store.getConv(projection, room.key);
	assert(bridged?.type === "room", "the room is a room");
	assert(!bridged.grants.has("files"), "a withheld files facet is no files grant");
	assert(bridged.carries?.previews === false && bridged.carries.typing === false, "the statement was kept");
	// The same room, once it holds the facet and says it carries everything.
	store.setRoomView(projection, room.key, {
		...view(),
		carries: { previews: true, typing: true },
		canPostFiles: true,
	});
	const roomConv = store.getConv(projection, room.key);
	assert(roomConv?.type === "room" && roomConv.grants.has("files"), "holding the facet is the files grant");
	assert(roomConv.carries?.previews === true, "the statement moved with the view");
	// A view that stops carrying the statement clears it rather than leaving
	// the previous snapshot's word standing.
	store.setRoomView(projection, room.key, { ...view(), carries: null });
	const unsaid = store.getConv(projection, room.key);
	assert(unsaid?.type === "room" && unsaid.carries === undefined, "an unsaid statement is absent, not false");
});

Deno.test("IRC snapshots update seat progress and retire stale identity", () => {
	const room = store.ensureRoom(projection, dirId("irc-seat-state"), "bridge");
	for (const state of ["connecting", "linked", "failed", "rooms"] as const) {
		store.setRoomView(projection, room.key, view(state));
		const roster = store.membersOf(projection, room.key);
		assert(roster.size === 2, "a seat projection minted another roster member");
		assert(roster.get("alice")?.seat?.state === state, `the ${state} seat was not shown`);
		assert(roster.get("alice")?.seat?.nick === "alice_irc", "the IRC nick was lost");
	}
	store.setRoomView(projection, room.key, view());
	assert(
		store.membersOf(projection, room.key).get("alice")?.seat === undefined,
		"a complete view kept a stale seat projection",
	);
});

Deno.test("IRC identity intent follows its network across bridged rooms", () => {
	const directory = dirId("irc-network-intent");
	const one = store.ensureRoom(projection, directory, "Libera/#one");
	const two = store.ensureRoom(projection, directory, "Libera/#two");
	for (const room of [one, two]) {
		store.setRoomView(projection, room.key, view("linked"));
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
