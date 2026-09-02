// Driving the IRC gateway over CapTP from a test, the way a reader's filled-in
// form drives it in production.
//
// The gateway speaks the generic bridge verbs now, so these helpers build the
// same answer records the operator pane would submit and hand them to the
// generic client. IRC's field ids are shared from the gateway projection, so a
// rename of the form fields breaks these helpers rather than drifting a second
// copy of the strings out of sync.

import type { Ref, Session } from "@glowcap/runtime";
import {
	addBridgeLease,
	type BridgeGateway,
	openBridgeConnection,
	removeBridgeLease,
	snapshotBridgeGateway,
} from "../../../lib/room/client_exports.ts";
import type { IrcNetworkChoice } from "../../../server/irc_gateway/model.ts";
import { IRC_GATEWAY_FIELDS } from "../../../server/irc_gateway/gateway_projection.ts";

function connectionAnswers(choice: IrcNetworkChoice): string {
	const answers: Record<string, string> = {
		[IRC_GATEWAY_FIELDS.name]: choice.network,
		[IRC_GATEWAY_FIELDS.host]: choice.host,
		[IRC_GATEWAY_FIELDS.port]: String(choice.port),
		[IRC_GATEWAY_FIELDS.nick]: choice.nick,
		[IRC_GATEWAY_FIELDS.tls]: choice.tls ? "on" : "",
	};
	if (choice.sasl != null) {
		answers[IRC_GATEWAY_FIELDS.account] = choice.sasl.account;
		answers[IRC_GATEWAY_FIELDS.password] = choice.sasl.password;
	}
	return JSON.stringify(answers);
}

function channelAnswers(channel: string): string {
	return JSON.stringify({ [IRC_GATEWAY_FIELDS.channel]: channel.replace(/^#+/, "") });
}

/** Open an IRC network connection. Resolves with the connection id (its name). */
export function openIrcNetwork(session: Session, gateway: Ref, choice: IrcNetworkChoice): Promise<string> {
	return openBridgeConnection(session, gateway, connectionAnswers(choice));
}

/** Bridge one channel under a network. Resolves with the lease's name (`#channel`). */
export function joinIrcChannel(session: Session, gateway: Ref, network: string, channel: string): Promise<string> {
	return addBridgeLease(session, gateway, network, channelAnswers(channel));
}

/** Part one bridged channel from a network. */
export function partIrcChannel(session: Session, gateway: Ref, network: string, channel: string): Promise<void> {
	return removeBridgeLease(session, gateway, network, channel);
}

/** Close a network connection and every channel under it. */
export { closeBridgeConnection as closeIrcNetwork } from "../../../lib/room/client_exports.ts";

/** Read the gateway's whole description. */
export function snapshotIrcGateway(session: Session, gateway: Ref): Promise<BridgeGateway> {
	return snapshotBridgeGateway(session, gateway);
}
