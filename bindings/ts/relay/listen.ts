// FFI registered accepts for the relay profiles. The driver owns the
// registration socket, admission, handshake, events, and terminal release;
// this module installs the relay provider with its two routes and projects
// the listener into the TypeScript API, the same shape `@glowcap/tcp`'s
// listen has.
//
// The provider hosts one registration route per loop (the deployed
// rendezvous protocol queues inbound legs by durable designator without a
// channel-profile discriminator). FFI installation is the configuration
// authority: repeated installation accepts only the same complete route and
// trust snapshot.

import {
	DriverListener,
	DriverServer,
	type Host,
	openDriverServer,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_NOISE_RELAY,
} from "@glowcap/runtime/transport";
import type { Codec, DriverLoop } from "@glowcap/runtime/transport";
import { installProvider, type TlsTrust } from "./transport.ts";
import { relayRoute } from "./route.ts";

/** Options for opening a relay listener. `relayUrl` and `registerUrl` are required, and the remaining fields choose
 * trust, codec, cancellation, and which Host or identity the listener uses. */
export interface RelayListenOptions {
	/** WebSocket URL peers dial through, carried in the announced locator. */
	readonly relayUrl: string;
	/** Registration endpoint this listener holds inbound sockets at. */
	readonly registerUrl: string;
	/** Immutable trust snapshot used by WSS opens. */
	readonly trust?: TlsTrust;
	/** Cancel listener construction before the driver reports readiness. */
	readonly signal?: AbortSignal;
	/** Reuse this Host's identity, publications, and handoff router. */
	readonly host?: Host;
	/** Reuse this 32-byte identity seed across restarts. */
	readonly seed?: Uint8Array;
	/** Wire codec for a newly minted Host. */
	readonly codec?: Codec;
}

async function ensureRelayProvider(loop: DriverLoop, options: RelayListenOptions): Promise<void> {
	const relayUrl = relayRoute(options.relayUrl);
	await installProvider(loop, {
		relayUrl,
		registerUrl: options.registerUrl,
		trust: options.trust,
	});
}

function listenProfile(
	transport: string,
	options: RelayListenOptions,
): Promise<DriverServer> {
	return openDriverServer({
		host: options.host,
		seed: options.seed,
		codec: options.codec,
		async open(loop, adopt, ownedLoop) {
			await ensureRelayProvider(loop, options);
			// The provider registers as the listener opens, so a completed open is
			// the commit point: the relay answered and holds this peer's sockets.
			const listener = adopt(await DriverListener.open(loop, transport, "", options.signal));
			listener.select();
			return new DriverServer({ listener, ownedLoop });
		},
	});
}

/** Register the identity-addressed cleartext relay profile. */
export function listenKeyed(options: RelayListenOptions): Promise<DriverServer> {
	return listenProfile(TRANSPORT_KEYED_RELAY, options);
}

/** Register the Noise_XK-sealed relay profile. */
export function listenNoise(options: RelayListenOptions): Promise<DriverServer> {
	return listenProfile(TRANSPORT_NOISE_RELAY, options);
}
