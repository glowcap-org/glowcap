// Exact command admission at the IRC gateway capability.

import { JOIN_IRC, PART_IRC, SNAPSHOT } from "../../lib/protocol.ts";
import { parseIrcGatewaySnapshot } from "../../lib/irc_gateway_client.ts";
import { ircGatewayBehavior } from "../../server/irc_gateway_behavior.ts";
import { assert } from "../support/rooms_server.ts";

Deno.test("the IRC gateway refuses incomplete, surplus, and silently defaulted data", () => {
	const gateway = ircGatewayBehavior();
	const refused = (verb: string, args: Parameters<typeof gateway>[1]): boolean => {
		try {
			gateway(verb, args);
			return false;
		} catch {
			return true;
		}
	};
	const join = ["network", "#channel", "irc.example", 6697n, true, "bridge"];
	assert(refused(JOIN_IRC, join.slice(0, -1)), "joinIrc supplied a hidden default nick");
	assert(refused(JOIN_IRC, [...join, "surplus"]), "joinIrc accepted a partial SASL pair");
	assert(refused(JOIN_IRC, [...join, "account", "password", "surplus"]), "joinIrc accepted surplus data");
	assert(
		refused(JOIN_IRC, ["network", "#channel", "irc.example", 6697n, "tls", "bridge"]),
		"joinIrc accepted a non-boolean TLS choice",
	);
	assert(refused(PART_IRC, ["network", "#channel", "surplus"]), "partIrc accepted surplus data");
	assert(refused(PART_IRC, ["network", ""]), "partIrc accepted an empty channel");
	assert(refused(SNAPSHOT, ["surplus"]), "snapshot accepted surplus data");
});

Deno.test("the IRC gateway snapshot parser refuses inexact rows", () => {
	const refused = (raw: Parameters<typeof parseIrcGatewaySnapshot>[0]): boolean => {
		try {
			parseIrcGatewaySnapshot(raw);
			return false;
		} catch {
			return true;
		}
	};
	assert(
		refused([["network", "#channel", "network/#channel", "up", "irc.example:6697", "surplus"]]),
		"the snapshot parser truncated a surplus field",
	);
	assert(
		refused([["", "#channel", "network/#channel", "up", "irc.example:6697"]]),
		"the snapshot parser accepted an empty network",
	);
});
