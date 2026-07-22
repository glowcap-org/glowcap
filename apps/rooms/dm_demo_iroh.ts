// Rooms direct-message-by-introduction over iroh (three-party handoff), the
// `Direct` posture: the gift names Bob's node id and its direct addresses.
// Sibling of `dm_demo.ts` over encrypted QUIC; the handoff choreography is
// shared in `runDmHandoff`. Run by `zig build demo-rooms-dm-iroh`.

import { Host } from "@pancake/stack";
import { listenIroh, Reachability } from "@pancake/iroh";
import { runDmHandoff, waitUntil } from "./dm_handoff.ts";

// An iroh endpoint is dialable by direct address only once it has learned one.
const DIRECT_ADDRESSES_MS = 20_000;

runDmHandoff({
	label: "rooms-dm-iroh",
	dmText: "hi Bob, privately, from Carol, over iroh",
	timeoutMs: 20_000,
	bullets: [
		"the room introduced Carol to Bob over iroh (handoff-give with direct addresses)",
		"Bob accepted 1 iroh connection: Carol's direct dial (register fetched dm on the room session)",
		"Carol's DM reached Bob over her own encrypted-QUIC connection",
	],
	async startBob(dm) {
		const seed = crypto.getRandomValues(new Uint8Array(32));
		const host = new Host(seed);
		host.publishGiftable("dm", dm);
		const bob = listenIroh(Reachability.Direct, seed, host);
		await waitUntil(
			() => bob.directAddresses.length > 0,
			DIRECT_ADDRESSES_MS,
			"Bob direct addresses",
		);
		return { host, sessions: bob, locator: bob.uri, close: () => bob.close() };
	},
	async startRoom() {
		const seed = crypto.getRandomValues(new Uint8Array(32));
		const room = listenIroh(Reachability.Direct, seed, new Host(seed));
		await waitUntil(
			() => room.directAddresses.length > 0,
			DIRECT_ADDRESSES_MS,
			"Room direct addresses",
		);
		return { listener: room, locator: room.uri, close: () => room.close() };
	},
});
