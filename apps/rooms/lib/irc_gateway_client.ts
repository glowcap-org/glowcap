// The client's side of the IRC gateway capability.
//
// The gateway is a second object the server publishes under an unguessable
// name; holding that name is the whole of the authority. Taking it is the
// shared operations flow; what it answers — the bridged-channel rows below,
// and the join and part verbs — is what this module owns.

import type { Argument, Ref, Session } from "@pancake/runtime";
import * as z from "zod/mini";
import { JOIN_IRC, PART_IRC, SNAPSHOT } from "./protocol.ts";
import { ask } from "./ask.ts";
import { takeOperationsCap } from "./operations.ts";
import { MAX_OPERATIONS_ROWS } from "./limits.ts";
import { nonemptyText } from "./schema.ts";

const ircNetwork = nonemptyText(64 * 1024);
const ircChannel = nonemptyText(64 * 1024);
const ircRoomName = nonemptyText(64 * 1024);
const ircStatus = z.enum(["connecting", "up", "backoff"]);
const ircEndpoint = nonemptyText(64 * 1024);
const ircHost = nonemptyText(64 * 1024);
const ircNick = nonemptyText(64 * 1024);
const ircAccount = nonemptyText(64 * 1024);
const ircPassword = nonemptyText(64 * 1024);
const ircPort = z.int().check(z.gte(1), z.lte(65535));

/** One channel the gateway currently bridges. */
export const IrcGatewayRowSchema = z.strictObject({
	network: ircNetwork,
	channel: ircChannel,
	roomName: ircRoomName,
	status: ircStatus,
	endpoint: ircEndpoint,
});

export type IrcGatewayRow = z.infer<typeof IrcGatewayRowSchema>;

export const IrcJoinChoiceSchema = z.strictObject({
	network: ircNetwork,
	channel: ircChannel,
	host: ircHost,
	port: ircPort,
	tls: z.boolean(),
	nick: ircNick,
	sasl: z.optional(z.strictObject({
		account: ircAccount,
		password: ircPassword,
	})),
});

export type IrcJoinChoice = z.infer<typeof IrcJoinChoiceSchema>;

const IrcGatewayWireRowSchema = z.tuple([
	ircNetwork,
	ircChannel,
	ircRoomName,
	ircStatus,
	ircEndpoint,
]);
const IrcGatewaySnapshotSchema = z.array(IrcGatewayWireRowSchema).check(z.maxLength(MAX_OPERATIONS_ROWS));

const IrcJoinWireSchema = z.union([
	z.tuple([ircNetwork, ircChannel, ircHost, z.bigint(), z.boolean(), ircNick]),
	z.tuple([ircNetwork, ircChannel, ircHost, z.bigint(), z.boolean(), ircNick, ircAccount, ircPassword]),
]);

/** Parse the gateway's exact join command without supplying values the caller
 * did not send. The six-field form carries no credentials; the eight-field
 * form carries a complete SASL pair. */
export function parseIrcJoinArguments(args: readonly Argument[]): IrcJoinChoice {
	const parsed = z.safeParse(IrcJoinWireSchema, args);
	if (!parsed.success) {
		throw new Error("joinIrc needs network, channel, host, port, TLS, nick, and optional SASL credentials");
	}
	const [network, channel, host, rawPort, tls, nick] = parsed.data;
	const port = Number(rawPort);
	if (!Number.isSafeInteger(port) || port < 1 || port > 65535) {
		throw new Error("joinIrc needs a real port");
	}
	return parsed.data.length === 6
		? { network, channel, host, port, tls, nick }
		: { network, channel, host, port, tls, nick, sasl: { account: parsed.data[6], password: parsed.data[7] } };
}

function ircJoinArguments(choice: IrcJoinChoice): Argument[] {
	const args: Argument[] = [
		choice.network,
		choice.channel,
		choice.host,
		BigInt(choice.port),
		choice.tls,
		choice.nick,
	];
	if (choice.sasl != null) args.push(choice.sasl.account, choice.sasl.password);
	return args;
}

/** Fetch the gateway and ask it what it currently bridges. */
export async function takeIrcGateway(session: Session, pasted: string): Promise<{
	cap: Ref;
	rows: IrcGatewayRow[];
}> {
	const { cap, taken } = await takeOperationsCap(session, pasted, (fetched) => snapshotIrcGateway(session, fetched));
	return { cap, rows: taken };
}

/** Ask a gateway already in hand for its bridged channels. */
export async function snapshotIrcGateway(session: Session, cap: Ref): Promise<IrcGatewayRow[]> {
	const raw = await ask(session, cap, SNAPSHOT, [], "the IRC gateway did not answer");
	return parseIrcGatewaySnapshot(raw);
}

/** Validate and adapt the gateway's tuple rows at the wire boundary. */
export function parseIrcGatewaySnapshot(raw: Argument): IrcGatewayRow[] {
	const parsed = z.safeParse(IrcGatewaySnapshotSchema, raw);
	if (!parsed.success) throw new Error("the IRC gateway answered an invalid snapshot");
	return parsed.data.map(([network, channel, roomName, status, endpoint]) => ({
		network,
		channel,
		roomName,
		status,
		endpoint,
	}));
}

/** Bridge one channel; the answer is the room name it stands under. */
export async function joinIrcChannel(
	session: Session,
	cap: Ref,
	choice: IrcJoinChoice,
): Promise<string> {
	const name = await ask(
		session,
		cap,
		JOIN_IRC,
		ircJoinArguments(choice),
		"the gateway did not answer the join",
	);
	return typeof name === "string" ? name : "";
}

/** Part one bridged channel; its room leaves the directory with it. */
export async function partIrcChannel(
	session: Session,
	cap: Ref,
	network: string,
	channel: string,
): Promise<void> {
	await ask(session, cap, PART_IRC, [network, channel], "the gateway did not answer the part");
}
