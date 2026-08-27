// CapTP command admission for operator-managed IRC bridges.

import { type Argument, type Behavior, currentSession } from "@pancake/runtime";
import { validateSaslPlain } from "../irc/registration.ts";
import { parseIrcJoinArguments } from "../lib/irc_gateway_client.ts";
import { JOIN_IRC, PART_IRC, SNAPSHOT } from "../lib/protocol.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import { ircBridgeSnapshot, joinIrcBridge, partIrcBridge } from "./irc_gateway.ts";
import type { RoomServerOperationsState } from "./operations_state.ts";

export function ircGatewayBehavior(state: RoomServerOperationsState | null = null): Behavior {
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
		if (verb === JOIN_IRC) {
			const choice = parseIrcJoinArguments(args);
			if (choice.sasl != null) {
				if (!choice.tls) throw new Error("a registered account needs TLS; join with TLS on");
				validateSaslPlain(choice.sasl);
			}
			return joinIrcBridge(choice, state, true);
		}
		if (verb === PART_IRC) {
			if (
				args.length !== 2 || typeof args[0] !== "string" || args[0] === "" ||
				typeof args[1] !== "string" || args[1] === ""
			) {
				throw new Error("partIrc needs one network and channel");
			}
			const [network, channel] = args;
			return partIrcBridge(network, channel, state);
		}
		if (verb === SNAPSHOT) {
			if (args.length !== 0) throw new Error("snapshot takes no arguments");
			return ircBridgeSnapshot();
		}
		throw new Error(`the IRC gateway has no method ${verb}`);
	};
}
