// The client's side of the IRC gateway capability.
//
// The gateway is a second object the server publishes under an unguessable
// name; holding that name is the whole of the authority. Taking it is the
// shared operations flow; what it answers — the bridged-channel rows below,
// and the join and part verbs — is what this module owns.

import { type Argument, Ref, retainCleanupFailures, type Session } from "@pancake/runtime";
import * as z from "zod/mini";
import { SNAPSHOT } from "./protocol.ts";
import { CLOSE_IRC_NETWORK, IRC_NETWORK, JOIN_IRC, OPEN_IRC_NETWORK, PART_IRC } from "./protocol_irc.ts";
import { ask } from "./ask.ts";
import { takeOperationsCap } from "./operations.ts";
import { MAX_OPERATIONS_ROWS } from "./limits.ts";
import { nonemptyText } from "./schema.ts";

const ircNetwork = nonemptyText(64 * 1024);
const ircChannel = nonemptyText(64 * 1024);
const ircRoomName = nonemptyText(64 * 1024);
const ircPublicationId = nonemptyText(128);
const ircChannelStatus = z.enum(["connecting", "up", "backoff"]);
const ircNetworkStatus = z.enum(["dormant", "connecting", "up", "backoff"]);
const ircEndpoint = nonemptyText(64 * 1024);
const ircHost = nonemptyText(64 * 1024);
const ircNick = nonemptyText(64 * 1024);
const ircAccount = nonemptyText(64 * 1024);
const ircOptionalAccount = z.string().check(z.maxLength(64 * 1024));
const ircPassword = nonemptyText(64 * 1024);
const ircProblem = z.string().check(z.maxLength(64 * 1024));
const ircPort = z.int().check(z.gte(1), z.lte(65535));

/** One channel the gateway currently bridges. */
export const IrcGatewayRowSchema = z.strictObject({
	network: ircNetwork,
	channel: ircChannel,
	roomName: ircRoomName,
	/** Exact non-bearer directory identity for this bridge generation. */
	publicationId: ircPublicationId,
	status: ircChannelStatus,
	endpoint: ircEndpoint,
	problem: ircProblem,
});

export type IrcGatewayRow = z.infer<typeof IrcGatewayRowSchema>;

export const IrcNetworkRowSchema = z.strictObject({
	network: ircNetwork,
	status: ircNetworkStatus,
	endpoint: ircEndpoint,
	nick: ircNick,
	account: ircOptionalAccount,
	tls: z.boolean(),
	problem: ircProblem,
});
export type IrcNetworkRow = z.infer<typeof IrcNetworkRowSchema>;
export interface IrcGatewaySnapshot {
	readonly networks: IrcNetworkRow[];
	readonly bridged: IrcGatewayRow[];
}

const IrcNetworkChoiceShape = {
	network: ircNetwork,
	host: ircHost,
	port: ircPort,
	tls: z.boolean(),
	nick: ircNick,
	sasl: z.optional(z.strictObject({
		account: ircAccount,
		password: ircPassword,
	})),
};

export const IrcNetworkChoiceSchema = z.strictObject(IrcNetworkChoiceShape);
export type IrcNetworkChoice = z.infer<typeof IrcNetworkChoiceSchema>;

/** Exact compatibility for two claims about one logical IRC network. */
export function sameIrcNetworkChoice(left: IrcNetworkChoice, right: IrcNetworkChoice): boolean {
	return left.network.toLowerCase() === right.network.toLowerCase() &&
		left.host.toLowerCase() === right.host.toLowerCase() && left.port === right.port && left.tls === right.tls &&
		left.nick === right.nick && left.sasl?.account === right.sasl?.account &&
		left.sasl?.password === right.sasl?.password;
}

/** Durable server intent for one bridge. The publication id is correlation
 * identity, not bearer authority, and survives restoration of that intent. */
export const IrcBridgeIntentSchema = z.strictObject({
	network: ircNetwork,
	channel: ircChannel,
	publicationId: ircPublicationId,
});

export type IrcBridgeIntent = z.infer<typeof IrcBridgeIntentSchema>;

const IrcGatewayWireRowSchema = z.tuple([
	ircNetwork,
	ircChannel,
	ircRoomName,
	ircPublicationId,
	ircChannelStatus,
	ircEndpoint,
	ircProblem,
]);
const IrcNetworkWireRowSchema = z.tuple([
	ircNetwork,
	ircNetworkStatus,
	ircEndpoint,
	ircNick,
	ircOptionalAccount,
	z.boolean(),
	ircProblem,
]);
const IrcGatewaySnapshotSchema = z.tuple([
	z.array(IrcNetworkWireRowSchema).check(z.maxLength(MAX_OPERATIONS_ROWS)),
	z.array(IrcGatewayWireRowSchema).check(z.maxLength(MAX_OPERATIONS_ROWS)),
]);

const IrcNetworkWireSchema = z.union([
	z.tuple([ircNetwork, ircHost, z.bigint(), z.boolean(), ircNick]),
	z.tuple([ircNetwork, ircHost, z.bigint(), z.boolean(), ircNick, ircAccount, ircPassword]),
]);

/** Parse the gateway's exact network-open command without supplying values the
 * caller did not send. The five-field form carries no credentials; the seven-field
 * form carries a complete SASL pair. */
export function parseIrcNetworkArguments(args: readonly Argument[]): IrcNetworkChoice {
	const parsed = z.safeParse(IrcNetworkWireSchema, args);
	if (!parsed.success) {
		throw new Error("openIrcNetwork needs network, host, port, TLS, nick, and optional SASL credentials");
	}
	const [network, host, rawPort, tls, nick] = parsed.data;
	const port = Number(rawPort);
	if (!Number.isSafeInteger(port) || port < 1 || port > 65535) {
		throw new Error("openIrcNetwork needs a real port");
	}
	return parsed.data.length === 5
		? { network, host, port, tls, nick }
		: { network, host, port, tls, nick, sasl: { account: parsed.data[5], password: parsed.data[6] } };
}

function ircNetworkArguments(choice: IrcNetworkChoice): Argument[] {
	const args: Argument[] = [
		choice.network,
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
	snapshot: IrcGatewaySnapshot;
}> {
	const { cap, taken } = await takeOperationsCap(session, pasted, (fetched) => snapshotIrcGateway(session, fetched));
	return { cap, snapshot: taken };
}

/** Ask a gateway already in hand for its bridged channels. */
export async function snapshotIrcGateway(session: Session, cap: Ref): Promise<IrcGatewaySnapshot> {
	const raw = await ask(session, cap, SNAPSHOT, [], "the IRC gateway did not answer");
	return parseIrcGatewaySnapshot(raw);
}

/** Validate and adapt the gateway's tuple rows at the wire boundary. */
export function parseIrcGatewaySnapshot(raw: Argument): IrcGatewaySnapshot {
	const parsed = z.safeParse(IrcGatewaySnapshotSchema, raw);
	if (!parsed.success) throw new Error("the IRC gateway answered an invalid snapshot");
	const networks = parsed.data[0].map(([network, status, endpoint, nick, account, tls, problem]) => ({
		network,
		status,
		endpoint,
		nick,
		account,
		tls,
		problem,
	}));
	const bridged = parsed.data[1].map(([network, channel, roomName, publicationId, status, endpoint, problem]) => ({
		network,
		channel,
		roomName,
		publicationId,
		status,
		endpoint,
		problem,
	}));
	return { networks, bridged };
}

async function withIrcNetwork<T>(session: Session, network: Ref, use: (network: Ref) => Promise<T>): Promise<T> {
	let answer: T;
	try {
		answer = await use(network);
	} catch (error) {
		throw await retainCleanupFailures(error, [() => session.release(network)]);
	}
	session.release(network);
	return answer;
}

/** Part one bridged channel; its room leaves the directory with it. */
export async function partIrcChannel(
	session: Session,
	cap: Ref,
	network: string,
	channel: string,
): Promise<void> {
	const connection = await ask(
		session,
		cap,
		IRC_NETWORK,
		[network],
		"the gateway did not answer with the IRC network",
	);
	if (!(connection instanceof Ref)) throw new Error("the gateway did not return an IRC network capability");
	await withIrcNetwork(session, connection, async (networkCap) => {
		await ask(session, networkCap, PART_IRC, [channel], "the IRC network did not answer the part");
	});
}

/** Create one channel lease through an already retained network capability. */
export async function joinIrcChannel(
	session: Session,
	gateway: Ref,
	network: string,
	channel: string,
): Promise<string> {
	const connection = await ask(
		session,
		gateway,
		IRC_NETWORK,
		[network],
		"the gateway did not answer with the IRC network",
	);
	if (!(connection instanceof Ref)) throw new Error("the gateway did not return an IRC network capability");
	return await withIrcNetwork(session, connection, async (networkCap) => {
		const name = await ask(session, networkCap, JOIN_IRC, [channel], "the IRC network did not answer the join");
		return typeof name === "string" ? name : "";
	});
}

export async function openIrcNetwork(
	session: Session,
	gateway: Ref,
	choice: IrcNetworkChoice,
): Promise<Ref> {
	await ask(
		session,
		gateway,
		OPEN_IRC_NETWORK,
		ircNetworkArguments(choice),
		"the gateway did not open the IRC network",
	);
	const opened = await ask(
		session,
		gateway,
		IRC_NETWORK,
		[choice.network],
		"the gateway did not answer with the opened IRC network",
	);
	if (!(opened instanceof Ref)) throw new Error("the gateway did not return an IRC network capability");
	return opened;
}

export async function closeIrcNetwork(session: Session, gateway: Ref, network: string): Promise<void> {
	const connection = await ask(
		session,
		gateway,
		IRC_NETWORK,
		[network],
		"the gateway did not answer with the IRC network",
	);
	if (!(connection instanceof Ref)) throw new Error("the gateway did not return an IRC network capability");
	await withIrcNetwork(session, connection, async (networkCap) => {
		await ask(session, networkCap, CLOSE_IRC_NETWORK, [], "the IRC network did not close");
	});
}
