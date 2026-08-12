// Rooms direct-message-by-introduction over iroh (three-party handoff), the
// `Direct` posture: the gift names Bob's node id and its direct addresses.
// Sibling of `dm_demo.ts` over encrypted QUIC; the handoff choreography is
// shared in `runDmHandoff`. Run by `zig build demo-rooms-dm-iroh`.

import { listenIroh, Reachability } from "@pancake/iroh";
import { runDmHandoff, waitUntil } from "../lib/dm_handoff.ts";
import { roomsHost } from "../lib/locator.ts";

// An iroh endpoint is dialable by direct address only once it has learned one.
const DIRECT_ADDRESSES_MS = 20_000;

runDmHandoff({
	label: "rooms-dm-iroh",
	dmText: "hi Bob, privately, from Carol, over iroh",
	timeoutMs: 20_000,
	bullets: [
		"Carol's first introduce was refused pending; the room asked Bob for an inbox for her",
		"the room introduced Carol to Bob over iroh (handoff-give with direct addresses)",
		"Bob accepted 1 iroh connection: Carol's direct dial; nobody dialed Carol",
		"the DM arrived on the inbox Bob minted for Carol, so it named no sender",
	],
	async startMember(who) {
		const seed = crypto.getRandomValues(new Uint8Array(32));
		const host = roomsHost(seed);
		const member = await listenIroh({ reachability: Reachability.Direct }, seed, host);
		await waitUntil(
			() => member.directAddresses.length > 0,
			DIRECT_ADDRESSES_MS,
			`${who} direct addresses`,
		);
		return { host, sessions: member, locator: member.uri, close: () => member.close() };
	},
	async startRoom() {
		const seed = crypto.getRandomValues(new Uint8Array(32));
		const room = await listenIroh(
			{ reachability: Reachability.Direct },
			seed,
			roomsHost(seed),
		);
		await waitUntil(
			() => room.directAddresses.length > 0,
			DIRECT_ADDRESSES_MS,
			"Room direct addresses",
		);
		return { listener: room, locator: room.uri, close: () => room.close() };
	},
});
