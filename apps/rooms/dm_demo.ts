// Rooms direct-message-by-introduction demo (three-party handoff, gifter side),
// over loopback TCP. The handoff choreography and its three proofs live in
// `runDmHandoff`; this file supplies only the TCP flavour of standing Bob and
// the rendezvous room up. Run by `zig build demo-rooms-dm`.

import { Host, listen } from "@pancake/stack";
import { runDmHandoff } from "./dm_handoff.ts";
import { loopbackTcpDesignator } from "./deno/lib/locator.ts";

runDmHandoff({
	label: "rooms-dm",
	dmText: "hi Bob, privately, from Carol",
	timeoutMs: 10_000,
	bullets: [
		"the room introduced Carol to Bob (a desc:handoff-give, redeemed transparently)",
		"Bob accepted 1 connection: Carol's direct dial (register fetched dm on the room session)",
		"Carol's DM reached Bob over her own connection — the room never relayed it",
	],
	async startBob(dm) {
		const host = new Host();
		host.publishGiftable("dm", dm);
		const bob = listen("127.0.0.1", 0, host);
		return {
			host,
			sessions: bob,
			locator: loopbackTcpDesignator(await bob.ready()),
			close: () => bob.close(),
		};
	},
	async startRoom() {
		const room = listen("127.0.0.1", 0);
		return {
			listener: room,
			locator: loopbackTcpDesignator(await room.ready()),
			close: () => room.close(),
		};
	},
});
