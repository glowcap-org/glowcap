// Checkpoint redaction removes room bearers without disturbing independent bridge intent.
import { emptyRoomsSessionState, redactRoomsSessionCapabilities } from "../lib/rooms_state.ts";
import { assertEquals } from "./assert.ts";

Deno.test("checkpoint redaction removes room bearers independently of bridge intent", () => {
	for (
		const bridgeIntent of [undefined, null, {
			scope: "bridge",
			action: "identify",
			answers: { account: "private-account" },
			secretsGiven: true,
		}]
	) {
		const checkpoint = emptyRoomsSessionState();
		checkpoint.conversations.push({
			kind: "room",
			id: "held",
			directory: "directory",
			name: "private",
			held: true,
			standing: null,
			draft: "keep my draft",
			link: "ocapn://peer.tcp/s/link-secret",
			manager: "ocapn://peer.tcp/s/manager-secret",
			steward: "ocapn://peer.tcp/s/steward-secret",
			...(bridgeIntent === undefined ? {} : { bridgeIntent }),
		});
		const encoded = JSON.stringify(redactRoomsSessionCapabilities(checkpoint));
		for (const secret of ["link-secret", "manager-secret", "steward-secret", "private-account"]) {
			assertEquals(encoded.includes(secret), false, `${secret} survived redaction`);
		}
		assertEquals(encoded.includes("keep my draft"), true);
		assertEquals(JSON.stringify(checkpoint).includes("link-secret"), true, "projection changed the owner");
	}
});
