// Rooms direct-message-by-introduction demo (three-party handoff, gifter side),
// over loopback TCP. The handoff choreography and its three proofs live in
// `runDmHandoff`; this file supplies only the TCP flavour of standing Bob and
// the rendezvous room up. Run by `zig build demo-rooms-dm`.

import { runDmHandoff } from "../lib/dm_handoff.ts";
import { loopbackTcpDesignator, roomsHost, roomsListen } from "../lib/locator.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";

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
		const host = roomsHost();
		const member = await roomsListen("127.0.0.1", 0, host);
		const runtime = await openRoomsRuntime({ host });
		return {
			host,
			runtime,
			sessions: member,
			locator: loopbackTcpDesignator(member.port),
			async close() {
				member.close();
				await runtime.close();
			},
		};
	},
	async startRoom() {
		const room = await roomsListen("127.0.0.1", 0);
		return {
			host: room.host,
			listener: room,
			locator: loopbackTcpDesignator(room.port),
			close: () => room.close(),
		};
	},
});
