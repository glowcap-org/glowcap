// Rooms DM-by-introduction over iroh Discovery: the gift names Bob by node id
// alone, with no direct addresses, and Carol resolves it through n0 discovery
// (relays + DNS/pkarr). Reaches the real internet, so it is opt-in:
// `zig build demo-rooms-dm-iroh-discovery` (needs internet). The handoff
// choreography is shared in `runDmHandoff`.

import { formatPeerUri } from "@pancake/stack";
import { roomsHost } from "../lib/locator.ts";
import { listenIroh, Reachability } from "@pancake/iroh";
import { runDmHandoff } from "../lib/dm_handoff.ts";

runDmHandoff({
	label: "rooms-dm-iroh-discovery",
	dmText: "hi Bob, privately, from Carol, by node id over iroh discovery",
	timeoutMs: 150_000,
	bullets: [
		"Carol's first introduce was refused pending; the room asked Bob for an inbox for her",
		"the room introduced Carol to Bob over iroh discovery (exporter by node id alone)",
		"Bob accepted 1 iroh connection: Carol's direct dial by id; nobody dialed Carol",
		"the DM arrived on the inbox Bob minted for Carol, so it named no sender",
	],
	startMember(who) {
		const host = roomsHost();
		const member = listenIroh({ reachability: Reachability.Discovery }, undefined, host);
		const locator = formatPeerUri("iroh", member.nodeId);
		console.log(`rooms-dm-iroh-discovery: ${who} published ${locator} (id only)`);
		return { host, sessions: member, locator, close: () => member.close() };
	},
	startRoom() {
		const room = listenIroh({ reachability: Reachability.Discovery }, undefined, roomsHost());
		const locator = formatPeerUri("iroh", room.nodeId);
		console.log(`rooms-dm-iroh-discovery: Room published ${locator} (id only)`);
		return { listener: room, locator, close: () => room.close() };
	},
});
