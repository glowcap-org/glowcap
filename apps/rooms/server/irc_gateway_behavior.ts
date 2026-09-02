// CapTP command admission for operator-managed IRC bridges, spoken as a
// generic bridge gateway: the verbs and the forms are bridge-neutral, and this
// file maps them onto IRC's own network and channel operations.

import { type Argument, type Behavior, currentSession } from "@glowcap/runtime";
import { validateSaslPlain } from "../irc/registration.ts";
import { SNAPSHOT } from "../lib/protocol.ts";
import {
	ADD_LEASE,
	CLOSE_CONNECTION,
	GATEWAY_CONNECTION,
	OPEN_CONNECTION,
	REMOVE_LEASE,
} from "../lib/bridge/gateway.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import {
	closeIrcNetwork,
	ircGatewaySnapshot,
	ircNetworkChoice,
	joinIrcBridge,
	openIrcNetwork,
	partIrcBridge,
} from "./irc_gateway.ts";
import { connectionChoiceFromAnswers, leaseChannelFromAnswers } from "./irc_gateway/gateway_projection.ts";
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
		if (verb === OPEN_CONNECTION) {
			if (args.length !== 1 || typeof args[0] !== "string") {
				throw new Error("openConnection needs one answers record");
			}
			const choice = connectionChoiceFromAnswers(args[0]);
			if (choice.sasl != null) {
				if (!choice.tls) throw new Error("a registered account needs TLS; open the connection with TLS on");
				validateSaslPlain(choice.sasl);
			}
			const session = currentSession();
			if (session == null) throw new Error("the IRC gateway is reachable only over a session");
			// Capability answers must be minted in the served turn. Opening may
			// await durable storage, so it acknowledges the retained name; the
			// client fetches that connection's capability in its next turn.
			return openIrcNetwork(ctx, choice, state, true).then(() => choice.network);
		}
		if (verb === GATEWAY_CONNECTION) {
			if (args.length !== 1 || typeof args[0] !== "string" || args[0] === "") {
				throw new Error("connection needs one connection id");
			}
			const choice = ircNetworkChoice(ctx, args[0]);
			if (choice == null) throw new Error(`connection ${args[0]} is not open`);
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
		if (verb === ADD_LEASE) {
			if (args.length !== 1 || typeof args[0] !== "string") {
				throw new Error("addLease needs one answers record");
			}
			const channel = leaseChannelFromAnswers(args[0]);
			return joinIrcBridge(ctx, network, channel, state, true, crypto.randomUUID(), authorities);
		}
		if (verb === REMOVE_LEASE) {
			if (args.length !== 1 || typeof args[0] !== "string" || args[0] === "") {
				throw new Error("removeLease needs one lease id");
			}
			return partIrcBridge(ctx, network, args[0], state);
		}
		if (verb === CLOSE_CONNECTION) {
			if (args.length !== 0) throw new Error("closeConnection takes no arguments");
			return closeIrcNetwork(ctx, network, state);
		}
		throw new Error(`the connection has no method ${verb}`);
	};
}
