// Rooms direct-message-by-introduction demo (three-party handoff, gifter side),
// over loopback TCP. The handoff choreography and its three proofs live in
// `runDmHandoff`; this file supplies only the TCP flavour of standing Bob and
// the rendezvous room up. Run by `zig build demo-rooms-dm`.

import { Host, listen } from "@pancake/stack";
import { runDmHandoff } from "../lib/dm_handoff.ts";
import { loopbackTcpDesignator } from "../lib/locator.ts";

runDmHandoff({
	label: "rooms-dm",
	dmText: "hi Bob, privately, from Carol",
	timeoutMs: 10_000,
	bullets: [
		"Carol's first introduce was refused pending; the room asked Bob for an inbox for her",
		"the room introduced Carol to Bob (a desc:handoff-give, redeemed transparently)",
		"Bob accepted 1 connection: Carol's direct dial; nobody dialed Carol",
		"the DM arrived on the inbox Bob minted for Carol, so it named no sender",
	],
	async startMember(_who) {
		const host = new Host();
		const member = listen("127.0.0.1", 0, host);
		return {
			host,
			sessions: member,
			locator: loopbackTcpDesignator(await member.ready()),
			close: () => member.close(),
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
