// Rooms direct-message-by-introduction demo (three-party handoff, gifter side),
// over loopback TCP. This orchestrator starts the native Rust rooms-server.
// The handoff choreography and its three proofs live in `runDmHandoff`.
// Run by `zig build demo-rooms-dm`.

import { startServer } from "../test/support/native_server.ts";
import { runDmHandoff } from "./dm_handoff.ts";
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
	startRoom: () => startServer(),
});
