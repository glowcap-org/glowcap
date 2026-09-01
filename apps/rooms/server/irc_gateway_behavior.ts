// CapTP command admission for operator-managed IRC bridges.

import { type Argument, type Behavior, currentSession } from "@pancake/runtime";
import { validateSaslPlain } from "../irc/registration.ts";
import { parseIrcNetworkArguments } from "../lib/irc_gateway_client.ts";
import { SNAPSHOT } from "../lib/protocol.ts";
import { CLOSE_IRC_NETWORK, IRC_NETWORK, JOIN_IRC, OPEN_IRC_NETWORK, PART_IRC } from "../lib/protocol_irc.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import {
	closeIrcNetwork,
	ircBridgeSnapshot,
	ircGatewaySnapshot,
	ircNetworkChoice,
	joinIrcBridge,
	openIrcNetwork,
	partIrcBridge,
} from "./irc_gateway.ts";
import type { RoomServerOperationsState } from "./operations_state.ts";
import type { IrcBridgeAuthorities } from "./irc_gateway/authority.ts";
import type { RoomServerContext } from "./context.ts";

export function ircGatewayBehavior(
	ctx: RoomServerContext,
	state: RoomServerOperationsState | null = null,
	authorities: IrcBridgeAuthorities | null = null,
): Behavior {
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		if (hasCapabilityArguments(args)) {
			const session = currentSession();
			if (session == null) throw new Error("the IRC gateway is reachable only over a session");
			throwAfterReleasingCapabilities(
				session,
				args,
				new Error(`IRC gateway ${verb} does not take capability arguments`),
			);
		}
		if (verb === OPEN_IRC_NETWORK) {
			const choice = parseIrcNetworkArguments(args);
			if (choice.sasl != null) {
				if (!choice.tls) throw new Error("a registered account needs TLS; open the network with TLS on");
				validateSaslPlain(choice.sasl);
			}
			const session = currentSession();
			if (session == null) throw new Error("the IRC gateway is reachable only over a session");
			// Capability answers must be minted in the served turn. Opening may
			// await durable storage, so it acknowledges the retained name; the
			// client fetches that name's network capability in its next turn.
			return openIrcNetwork(ctx, choice, state, true).then(() => choice.network);
		}
		if (verb === IRC_NETWORK) {
			if (args.length !== 1 || typeof args[0] !== "string" || args[0] === "") {
				throw new Error("ircNetwork needs one network name");
			}
			const choice = ircNetworkChoice(ctx, args[0]);
			if (choice == null) throw new Error(`IRC network ${args[0]} is not open`);
			const session = currentSession();
			if (session == null) throw new Error("the IRC gateway is reachable only over a session");
			return session.spawn(ircNetworkBehavior(ctx, choice.network, state, authorities));
		}
		if (verb === SNAPSHOT) {
			if (args.length !== 0) throw new Error("snapshot takes no arguments");
			return ircGatewaySnapshot(ctx);
		}
		throw new Error(`the IRC gateway has no method ${verb}`);
	};
}

function ircNetworkBehavior(
	ctx: RoomServerContext,
	network: string,
	state: RoomServerOperationsState | null,
	authorities: IrcBridgeAuthorities | null,
): Behavior {
	return (verb, args) => {
		if (hasCapabilityArguments(args)) {
			const session = currentSession();
			if (session == null) throw new Error("the IRC network is reachable only over a session");
			throwAfterReleasingCapabilities(session, args, new Error(`IRC network ${verb} does not take capabilities`));
		}
		if (verb === JOIN_IRC) {
			if (args.length !== 1 || typeof args[0] !== "string" || args[0] === "") {
				throw new Error("joinIrc needs one channel");
			}
			return joinIrcBridge(ctx, network, args[0], state, true, crypto.randomUUID(), authorities);
		}
		if (verb === PART_IRC) {
			if (args.length !== 1 || typeof args[0] !== "string" || args[0] === "") {
				throw new Error("partIrc needs one channel");
			}
			return partIrcBridge(ctx, network, args[0], state);
		}
		if (verb === CLOSE_IRC_NETWORK) {
			if (args.length !== 0) throw new Error("closeIrcNetwork takes no arguments");
			return closeIrcNetwork(ctx, network, state);
		}
		if (verb === SNAPSHOT) {
			if (args.length !== 0) throw new Error("snapshot takes no arguments");
			return ircBridgeSnapshot(ctx).filter((row) =>
				Array.isArray(row) && typeof row[0] === "string" && row[0].toLowerCase() === network.toLowerCase()
			);
		}
		throw new Error(`the IRC network has no method ${verb}`);
	};
}
