// Credential custody at the gateway boundary: a password may only be handed
// to an encrypted IRC leg, and malformed pairs are refused before any dial.

import { openIrcNetwork } from "./wire.ts";
import { loopbackTcpDesignator, roomsHost, roomsListen } from "../../../lib/locator.ts";
import { ircGatewayBehavior } from "../../../server/irc_gateway_behavior.ts";
import { assert, dial, roomsTest, within } from "../../support/rooms_server.ts";
import { RoomServer } from "../../../server/room_server.ts";

roomsTest("a registered account is refused over cleartext, and validated", async () => {
	const roomServer = new RoomServer();
	const server = await roomsListen("127.0.0.1", 0, roomsHost());
	const serving = (async () => {
		for await (const session of server) {
			session.publish("gw", ircGatewayBehavior(roomServer));
			void session.serve().catch(() => {});
		}
	})();
	const session = await dial(loopbackTcpDesignator(server.port));
	try {
		const gw = await session.fetch("gw");
		let refused = "";
		try {
			await within(
				openIrcNetwork(session, gw, {
					network: "net2",
					host: "127.0.0.1",
					port: 6667,
					tls: false,
					nick: "gwbot",
					sasl: { account: "acct", password: "pw" },
				}),
				"the cleartext refusal",
			);
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused.includes("TLS"), `sasl over cleartext was not refused for TLS: "${refused}"`);
		refused = "";
		try {
			await within(
				openIrcNetwork(session, gw, {
					network: "net2",
					host: "127.0.0.1",
					port: 6697,
					tls: true,
					nick: "gwbot",
					sasl: { account: "acct", password: "" },
				}),
				"the malformed-credential refusal",
			);
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused !== "", "an account with no password was not refused");
	} finally {
		await session.close().catch(() => {});
		(server as unknown as { close?: () => void }).close?.();
		await Promise.allSettled([serving]);
	}
});
