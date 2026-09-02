// Exact command admission at the bridge gateway capability, and the strictness
// of the gateway description on the wire.

import { SNAPSHOT } from "../../../lib/protocol.ts";
import { ADD_LEASE, GATEWAY_CONNECTION, OPEN_CONNECTION } from "../../../lib/bridge/gateway.ts";
import { type BridgeForm } from "../../../lib/bridge/form.ts";
import { type BridgeGateway, encodeBridgeGateway, parseBridgeGateway } from "../../../lib/bridge/gateway.ts";
import { ircGatewayBehavior } from "../../../server/irc_gateway_behavior.ts";
import {
	connectionChoiceFromAnswers,
	type IrcBridgeSnapshotSource,
	leaseChannelFromAnswers,
	projectBridgeGateway,
} from "../../../server/irc_gateway/gateway_projection.ts";
import type { OperatorIrcNetworks } from "../../../server/irc_gateway/networks.ts";
import { assert } from "../../support/rooms_server.ts";
import { RoomServer } from "../../../server/room_server.ts";

Deno.test("the bridge gateway refuses incomplete, surplus, and silently defaulted data", () => {
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
	const answers = (fields: Record<string, string>): string[] => [JSON.stringify(fields)];
	assert(refused(OPEN_CONNECTION, []), "openConnection accepted no answers record");
	assert(refused(OPEN_CONNECTION, ["{"]), "openConnection accepted answers that are not JSON");
	assert(refused(OPEN_CONNECTION, answers({})), "openConnection supplied hidden defaults for a missing name");
	assert(
		refused(OPEN_CONNECTION, answers({ name: "n", host: "irc.example", nick: "feed", port: "not-a-port" })),
		"openConnection accepted a non-numeric port",
	);
	assert(
		refused(
			OPEN_CONNECTION,
			answers({ name: "n", host: "irc.example", nick: "feed", tls: "", account: "a", password: "p" }),
		),
		"openConnection took a login onto a cleartext connection",
	);
	assert(
		refused(OPEN_CONNECTION, answers({ name: "n", host: "irc.example", nick: "feed", tls: "on", account: "a" })),
		"openConnection took a login with no password",
	);
	assert(refused(GATEWAY_CONNECTION, [""]), "connection accepted an empty id");
	assert(refused(GATEWAY_CONNECTION, ["unknown"]), "connection answered for a network that is not open");
	assert(refused(SNAPSHOT, ["surplus"]), "snapshot accepted surplus data");
	assert(refused(ADD_LEASE, answers({ channel: "room" })), "the gateway leased a channel without a connection");
});

Deno.test("the gateway description parser refuses inexact rows", () => {
	const form: BridgeForm = {
		scope: "connection",
		title: "New connection",
		said: "",
		fields: [],
		actions: [{ id: "open", label: "Open", busyLabel: "Opening…", tone: "primary", remembered: false }],
	};
	const gateway: BridgeGateway = {
		title: "IRC bridges",
		description: "",
		connectionNoun: "connection",
		connectionNounPlural: "connections",
		leaseNoun: "channel",
		leaseNounPlural: "channels",
		leaseRemoval: { label: "Part", say: "Parting closes the room.", keep: "Keep channel", commit: "Part channel" },
		connectionForm: form,
		leaseForm: { ...form, scope: "lease", title: "Add channel" },
		connections: [{
			id: "network",
			title: "network",
			facts: [],
			status: { label: "connected", tone: "ok" },
			problem: "",
			leases: [{
				id: "#channel",
				title: "#channel",
				status: { label: "live", tone: "ok" },
				problem: "",
				roomName: "network/#channel",
				publicationId: "publication",
			}],
		}],
	};
	const exact = parseBridgeGateway(encodeBridgeGateway(gateway));
	assert(
		exact.connections[0]?.leases[0]?.publicationId === "publication",
		"the description parser did not retain the bridge publication identity",
	);
	const refused = (raw: string): boolean => {
		try {
			parseBridgeGateway(raw);
			return false;
		} catch {
			return true;
		}
	};
	assert(refused("not json"), "the description parser accepted answers that are not JSON");
	assert(
		refused(JSON.stringify({ ...gateway, connections: [{ ...gateway.connections[0], surplus: "x" }] })),
		"the description parser accepted a surplus connection field",
	);
	const leaseless = { ...gateway.connections[0]!.leases[0]! } as Record<string, unknown>;
	delete leaseless.publicationId;
	assert(
		refused(JSON.stringify({ ...gateway, connections: [{ ...gateway.connections[0], leases: [leaseless] }] })),
		"the description parser accepted a lease with no publication field",
	);
});

Deno.test("connection answers keep a credential and a name exactly, or refuse", () => {
	const answers = (fields: Record<string, string>): string => JSON.stringify(fields);
	const refusal = (raw: string): string => {
		try {
			connectionChoiceFromAnswers(raw);
			return "";
		} catch (error) {
			return error instanceof Error ? error.message : String(error);
		}
	};
	assert(
		refusal(answers({ name: "n".repeat(129), host: "irc.example", nick: "feed" })).includes("name"),
		"a connection name past the description's own bound was admitted, bricking every later snapshot",
	);
	assert(
		refusal(answers({ name: "n".repeat(128), host: "irc.example", nick: "feed" })) === "",
		"a connection name at the bound was refused",
	);
	assert(
		refusal(answers({ name: "n", host: "irc.example", nick: "feed", tls: "on", password: "hunter2" }))
			.includes("account"),
		"a password with no account was silently dropped instead of refused",
	);
	const withSasl = connectionChoiceFromAnswers(
		answers({ name: "n", host: "irc.example", nick: "feed", tls: "on", account: "ada", password: "hunter2" }),
	);
	assert(withSasl.sasl?.account === "ada" && withSasl.sasl.password === "hunter2", "a full login did not travel");
});

Deno.test("a channel answer is completed with its mark, never rewritten", () => {
	const channel = (typed: string): string => leaseChannelFromAnswers(JSON.stringify({ channel: typed }));
	assert(channel("linux") === "#linux", "a bare name did not take the form's # mark");
	assert(channel("#linux") === "#linux", "a habit-typed # was doubled");
	assert(channel("##linux") === "##linux", "a double-hash channel was rewritten to a different channel");
	const refused = (typed: string): boolean => {
		try {
			leaseChannelFromAnswers(JSON.stringify({ channel: typed }));
			return false;
		} catch {
			return true;
		}
	};
	assert(refused("#"), "a bare mark passed as a channel name");
	assert(refused(`#${"c".repeat(128)}`), "a channel past the description's own bound was admitted");
});

Deno.test("a projected snapshot parses whatever the bridge's own diagnostics carry", () => {
	const networks = {
		snapshot: () => [[
			"libera",
			"backoff",
			`${"h".repeat(600)}:6697`,
			"feed",
			"",
			true,
			"TLS handshake failed: ".repeat(40),
		]],
	} as unknown as OperatorIrcNetworks;
	const bridges: IrcBridgeSnapshotSource[] = [{
		network: { choice: { network: "libera", host: "irc.example", port: 6697 } },
		channel: "#linux",
		roomName: "libera/#linux",
		entryId: "entry",
		status: "backoff",
		problem: "remote ERROR: ".repeat(40),
	}];
	const gateway = parseBridgeGateway(projectBridgeGateway(networks, bridges));
	const connection = gateway.connections[0]!;
	assert(connection.problem.endsWith("…"), "an overlong connection diagnostic was not cut to fit");
	assert(connection.leases[0]!.problem.endsWith("…"), "an overlong lease diagnostic was not cut to fit");
	assert(connection.facts[0]!.value.endsWith("…"), "an overlong endpoint fact was not cut to fit");
});

Deno.test("the description parser refuses an oversized answer before reading it", () => {
	try {
		parseBridgeGateway(`"${"x".repeat(300 * 1024)}"`);
		assert(false, "an oversized description was parsed");
	} catch (error) {
		const why = error instanceof Error ? error.message : String(error);
		assert(why.includes("too long"), `the refusal did not name the length: "${why}"`);
	}
});
