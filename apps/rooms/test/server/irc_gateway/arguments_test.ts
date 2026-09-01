// Exact command admission at the IRC gateway capability.

import { SNAPSHOT } from "../../../lib/protocol.ts";
import { IRC_NETWORK, JOIN_IRC, OPEN_IRC_NETWORK } from "../../../lib/protocol_irc.ts";
import { parseIrcGatewaySnapshot } from "../../../lib/irc_gateway_client.ts";
import { ircGatewayBehavior } from "../../../server/irc_gateway_behavior.ts";
import { assert } from "../../support/rooms_server.ts";
import { RoomServer } from "../../../server/room_server.ts";

Deno.test("the IRC gateway refuses incomplete, surplus, and silently defaulted data", () => {
	const roomServer = new RoomServer();
	const gateway = ircGatewayBehavior(roomServer);
	const refused = (verb: string, args: Parameters<typeof gateway>[1]): boolean => {
		try {
			gateway(verb, args);
			return false;
		} catch {
			return true;
		}
	};
	const open = ["network", "irc.example", 6697n, true, "bridge"];
	assert(refused(OPEN_IRC_NETWORK, open.slice(0, -1)), "openIrcNetwork supplied a hidden default nick");
	assert(refused(OPEN_IRC_NETWORK, [...open, "surplus"]), "openIrcNetwork accepted a partial SASL pair");
	assert(
		refused(OPEN_IRC_NETWORK, [...open, "account", "password", "surplus"]),
		"openIrcNetwork accepted surplus data",
	);
	assert(
		refused(OPEN_IRC_NETWORK, ["network", "irc.example", 6697n, "tls", "bridge"]),
		"openIrcNetwork accepted a non-boolean TLS choice",
	);
	assert(refused(IRC_NETWORK, ["network", "surplus"]), "ircNetwork accepted surplus data");
	assert(refused(IRC_NETWORK, [""]), "ircNetwork accepted an empty network");
	assert(refused(JOIN_IRC, ["#channel"]), "the gateway joined a channel without a network capability");
	assert(refused(SNAPSHOT, ["surplus"]), "snapshot accepted surplus data");
});

Deno.test("the IRC gateway snapshot parser refuses inexact rows", () => {
	const exact = parseIrcGatewaySnapshot([
		[["network", "up", "irc.example:6697", "bridge", "", true, ""]],
		[["network", "#channel", "network/#channel", "publication", "up", "irc.example:6697", ""]],
	]);
	assert(
		exact.bridged[0]?.publicationId === "publication",
		"the snapshot parser did not retain the bridge publication identity",
	);
	const refused = (raw: Parameters<typeof parseIrcGatewaySnapshot>[0]): boolean => {
		try {
			parseIrcGatewaySnapshot(raw);
			return false;
		} catch {
			return true;
		}
	};
	assert(
		refused([
			[],
			[["network", "#channel", "network/#channel", "publication", "up", "irc.example:6697", "", "surplus"]],
		]),
		"the snapshot parser truncated a surplus field",
	);
	assert(
		refused([[], [["", "#channel", "network/#channel", "publication", "up", "irc.example:6697", ""]]]),
		"the snapshot parser accepted an empty network",
	);
	assert(
		refused([[], [["network", "#channel", "network/#channel", "", "up", "irc.example:6697", ""]]]),
		"the current snapshot shape accepted an empty publication identity",
	);
});
