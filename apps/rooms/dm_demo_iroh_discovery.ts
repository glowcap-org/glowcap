// Rooms DM-by-introduction over iroh Discovery: the gift names Bob by node id
// alone, with no direct addresses, and Carol resolves it through n0 discovery
// (relays + DNS/pkarr). Reaches the real internet, so it is opt-in:
// `zig build demo-rooms-dm-iroh-discovery` (needs internet). The handoff
// choreography is shared in `runDmHandoff`.

import { formatPeerUri, Host } from "@pancake/stack";
import { listenIroh, Reachability } from "@pancake/iroh";
import { runDmHandoff } from "./dm_handoff.ts";

runDmHandoff({
	label: "rooms-dm-iroh-discovery",
	dmText: "hi Bob, privately, from Carol, by node id over iroh discovery",
	timeoutMs: 150_000,
	bullets: [
		"the room introduced Carol to Bob over iroh discovery (exporter by node id alone)",
		"Bob accepted 1 iroh connection: Carol's direct dial by id",
		"Carol's DM reached Bob over her own encrypted-QUIC connection",
	],
	async startBob(dm) {
		const host = new Host();
		host.publishGiftable("dm", dm);
		const bob = listenIroh(Reachability.Discovery, undefined, host);
		const locator = formatPeerUri("iroh", bob.nodeId);
		console.log(`rooms-dm-iroh-discovery: Bob published ${locator} (id only)`);
		return { host, sessions: bob, locator, close: () => bob.close() };
	},
	async startRoom() {
		const room = listenIroh(Reachability.Discovery, undefined, new Host());
		const locator = formatPeerUri("iroh", room.nodeId);
		console.log(`rooms-dm-iroh-discovery: Room published ${locator} (id only)`);
		return { listener: room, locator, close: () => room.close() };
	},
});
