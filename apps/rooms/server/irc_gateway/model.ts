// The IRC gateway's own domain types, shared across the server pieces that
// open networks, remember them, and describe them as a bridge gateway.
//
// A network choice is IRC's connection configuration: where to dial, whether
// to seal it, the feed nick, and optional SASL. A bridge intent is the durable
// server record that one channel is bridged, keyed by its publication identity.
// Neither is wire vocabulary any more — the gateway speaks the generic bridge
// verbs — so these are the words IRC keeps for itself behind that surface.

import * as z from "zod/mini";
import { nonemptyText } from "../../lib/schema.ts";

const ircNetwork = nonemptyText(64 * 1024);
const ircChannel = nonemptyText(64 * 1024);
const ircPublicationId = nonemptyText(128);
const ircHost = nonemptyText(64 * 1024);
const ircNick = nonemptyText(64 * 1024);
const ircAccount = nonemptyText(64 * 1024);
const ircPassword = nonemptyText(64 * 1024);
const ircPort = z.int().check(z.gte(1), z.lte(65535));

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
