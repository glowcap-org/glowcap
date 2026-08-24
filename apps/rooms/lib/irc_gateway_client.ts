// The client's side of the IRC gateway capability.
//
// The gateway is a second object the server publishes under an unguessable
// name; holding that name is the whole of the authority. Taking it is the
// shared operations flow; what it answers — the bridged-channel rows below,
// and the join and part verbs — is what this module owns.

import type { Ref, Session } from "@pancake/runtime";
import { JOIN_IRC, PART_IRC, SNAPSHOT } from "./protocol.ts";
import { ask } from "./ask.ts";
import { takeOperationsCap } from "./operations.ts";

/** One channel the gateway currently bridges. */
export interface IrcGatewayRow {
	network: string;
	channel: string;
	roomName: string;
	status: string;
	endpoint: string;
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
	if (!Array.isArray(raw)) throw new Error("the gateway snapshot was not a list");
	const rows: IrcGatewayRow[] = [];
	for (const row of raw) {
		if (!Array.isArray(row)) continue;
		const [network, channel, roomName, status, endpoint] = row;
		if (typeof network !== "string" || typeof channel !== "string") continue;
		rows.push({
			network,
			channel,
			roomName: typeof roomName === "string" ? roomName : "",
			status: typeof status === "string" ? status : "",
			endpoint: typeof endpoint === "string" ? endpoint : "",
		});
	}
	return rows;
}

/** Bridge one channel; the answer is the room name it stands under. */
export async function joinIrcChannel(
	session: Session,
	cap: Ref,
	choice: {
		network: string;
		channel: string;
		host: string;
		port: number;
		tls: boolean;
		nick: string;
		/** The feed's registered account, when the network requires one. The
		 * password travels once, to the server that will authenticate with
		 * it, and is never answered back. */
		sasl?: { account: string; password: string };
	},
): Promise<string> {
	const name = await ask(
		session,
		cap,
		JOIN_IRC,
		[
			choice.network,
			choice.channel,
			choice.host,
			BigInt(choice.port),
			choice.tls,
			choice.nick,
			choice.sasl?.account ?? "",
			choice.sasl?.password ?? "",
		],
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
