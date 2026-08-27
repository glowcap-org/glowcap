// CapTP command admission for listener administration.

import { type Argument, type Behavior, currentSession } from "@pancake/runtime";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../../lib/argument_custody.ts";
import { LISTENER_OPTION_NAMES, LISTENER_TRANSPORTS } from "../../lib/listeners.ts";
import { LISTENER_UNSUPPORTED, RoomError } from "../../lib/errors.ts";
import { DOWN, LIST, UP } from "../../lib/protocol.ts";
import { type AdminTransport, ListenerRegistry, type ListenerUpOptions } from "../listeners.ts";

/** Run listener lifecycle work after the behavior turn returns. The native
 * driver refuses listener operations that re-enter its active step. */
function offTurn<T>(work: () => Promise<T>): Promise<T> {
	return new Promise((resolve, reject) => {
		setTimeout(() => work().then(resolve, reject), 0);
	});
}

function listenerTransport(named: Argument | undefined): AdminTransport {
	if (typeof named !== "string" || named.length > 16) {
		throw new Error("up takes the transport as a short string");
	}
	const transport = LISTENER_TRANSPORTS.find((known) => known === named);
	if (transport == null) {
		throw new RoomError(
			LISTENER_UNSUPPORTED,
			`"${named}" names no transport this server knows (${LISTENER_TRANSPORTS.join(", ")})`,
		);
	}
	return transport;
}

function listenerUpOptions(transport: AdminTransport, raw: Argument | undefined): ListenerUpOptions {
	if (raw === undefined) return {};
	if (!Array.isArray(raw) || raw.length > 8) {
		throw new Error("up's options are a short list of [name, value] pairs");
	}
	const declared = new Set<string>(LISTENER_OPTION_NAMES[transport]);
	const seen = new Set<string>();
	const options: ListenerUpOptions = {};
	for (const pair of raw) {
		if (!Array.isArray(pair) || pair.length !== 2 || typeof pair[0] !== "string") {
			throw new Error("an up option is a [name, value] pair");
		}
		const [name, value] = pair;
		if (seen.has(name)) throw new Error(`the ${name} listener option was supplied twice`);
		seen.add(name);
		if (!declared.has(name)) {
			throw new Error(
				`a ${transport} listener has no "${name}" option` +
					(declared.size === 0 ? "" : ` (it takes ${[...declared].join(", ")})`),
			);
		}
		if (name === "port") {
			if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 65535) {
				throw new Error("port is an integer between 0 and 65535");
			}
			options.port = value;
			continue;
		}
		if (typeof value !== "string" || value.length === 0 || value.length > 4096) {
			throw new Error(`${name} is a non-empty string under 4 KiB`);
		}
		if (name === "bind") options.bind = value;
		else if (name === "advertise") options.advertise = value;
		else if (name === "relay") options.relayUrl = value;
	}
	return options;
}

/** The behavior published under the admin swiss. Admission stays synchronous;
 * only driver lifecycle work leaves the active turn. */
export function listenersBehavior(registry: ListenerRegistry): Behavior {
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		if (hasCapabilityArguments(args)) {
			const session = currentSession();
			if (session == null) throw new Error("listeners administration is reachable only over a session");
			throwAfterReleasingCapabilities(
				session,
				args,
				new Error(`listeners ${verb} does not take capability arguments`),
			);
		}
		if (verb === LIST) {
			if (args.length !== 0) throw new Error("list takes no arguments");
			return registry.rows();
		}
		if (verb === UP) {
			if (args.length < 1 || args.length > 2) {
				throw new Error("up takes a transport and, optionally, its named options");
			}
			const transport = listenerTransport(args[0]);
			const options = listenerUpOptions(transport, args[1]);
			return offTurn(() => registry.up(transport, options));
		}
		if (verb === DOWN) {
			if (args.length !== 1) throw new Error("down takes the listener's number");
			const id = args[0];
			if (typeof id !== "number" || !Number.isInteger(id) || id < 1 || id > 1_000_000) {
				throw new Error("down takes the number list answered");
			}
			return offTurn(() => registry.down(id)).then(() => undefined);
		}
		throw new Error(`listeners has no method ${verb}`);
	};
}
