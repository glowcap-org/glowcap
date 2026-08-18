// Rooms direct-message-by-introduction over iroh (three-party handoff), the
// `Direct` posture: the gift names Bob's node id and its direct addresses.
// Sibling of `dm_demo.ts` over encrypted QUIC; the handoff choreography is
// shared in `runDmHandoff`. Run by `zig build demo-rooms-dm-iroh`.

import * as iroh from "@pancake/iroh";
import { runDmHandoff, waitUntil } from "./dm_handoff.ts";
import { roomsHost } from "../lib/locator.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";

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
		const member = await iroh.listen({ reachability: iroh.Reachability.Direct }, { host });
		const runtime = await openRoomsRuntime({
			host,
			iroh: { reachability: iroh.Reachability.Direct },
		});
		await waitUntil(
			() => member.directAddresses.length > 0,
			DIRECT_ADDRESSES_MS,
			`${who} direct addresses`,
		);
		return {
			host,
			runtime,
			sessions: member,
			locator: member.uri,
			async close() {
				member.close();
				await runtime.close();
			},
		};
	},
	async startRoom() {
		const seed = crypto.getRandomValues(new Uint8Array(32));
		const room = await iroh.listen(
			{ reachability: iroh.Reachability.Direct },
			{ host: roomsHost(seed) },
		);
		await waitUntil(
			() => room.directAddresses.length > 0,
			DIRECT_ADDRESSES_MS,
			"Room direct addresses",
		);
		return { host: room.host, listener: room, locator: room.uri, close: () => room.close() };
	},
});
